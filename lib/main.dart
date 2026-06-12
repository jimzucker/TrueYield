// Copyright 2026 James A. Zucker
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'roc_data.dart';

/// Trailing return-of-capital % for [ticker] from the bundled YieldMax 19a-1
/// data ([kRocByTicker]), or null if the fund isn't known. Case-insensitive.
double? rocForTicker(String ticker) =>
    kRocByTicker[ticker.trim().toUpperCase()];

/// Optional CORS proxy origin for the Yahoo Finance endpoint, supplied at build
/// time via `--dart-define=YAHOO_PROXY=<origin>` (no trailing slash). It is used
/// only on the web build, where the browser enforces CORS and Yahoo's endpoint
/// sends no `Access-Control-Allow-Origin` header; native builds always call
/// Yahoo directly. Empty (the default) means "no proxy". See proxy/ for a
/// ready-to-deploy Cloudflare Worker.
const String kYahooProxy = String.fromEnvironment('YAHOO_PROXY');

/// Yahoo Finance chart API origin (no proxy). Native builds always hit this.
const String kYahooDirect = 'https://query2.finance.yahoo.com';

/// Resolves the chart-API base origin. The proxy is used **only on web** and
/// only when one is configured; every native target (iOS/Android/desktop) and
/// any web build without a proxy goes straight to Yahoo. Pure (takes [isWeb] as
/// a parameter) so both branches are unit-testable — `kIsWeb` is a
/// compile-time const that can't be toggled in a test.
String resolveYahooBase({required bool isWeb, required String proxy}) =>
    (isWeb && proxy.isNotEmpty) ? proxy : kYahooDirect;

/// Base origin for the Yahoo chart API: the CORS proxy on web (when configured),
/// Yahoo directly otherwise. The proxy forwards by path, so the rest of the URL
/// is identical either way.
String get yahooBase => resolveYahooBase(isWeb: kIsWeb, proxy: kYahooProxy);

void main() {
  runApp(const TrueYieldApp());
}

class TrueYieldApp extends StatelessWidget {
  const TrueYieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrueYield',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const YieldScreen(),
    );
  }
}

class DistributionEntry {
  final DateTime date;
  final double amount;
  // Per-distribution return-of-capital %. null means "use the global default"
  // (the ROC % the user typed on the Calculate tab). A non-null value is an
  // override the user set on the Distributions tab, e.g. from a YieldMax 19a-1
  // notice that gives the capital portion of that specific payout.
  final double? rocPct;
  const DistributionEntry({
    required this.date,
    required this.amount,
    this.rocPct,
  });
}

class PriceBar {
  final DateTime date;
  final double? close;
  const PriceBar({required this.date, required this.close});
}

/// One purchase of the ticker on [buyDate], sized by a share count and/or a
/// dollar cost — enter whichever you have:
///   • both → that IS your cost basis (price = cost ÷ shares), more accurate
///     than a market close (e.g. an odd fill or a transferred-in position);
///   • shares only → cost is derived from the buy-date market price;
///   • cost only → shares are derived from the buy-date market price.
/// If [sellDate] is null the lot is still held (unrealized); otherwise it was
/// sold on that date and books a realized gain. The default single lot — 1 share
/// bought at the start of the window, still held — reproduces the app's original
/// "one share a year ago" behavior exactly.
class Lot {
  final DateTime buyDate;
  final double? shares; // entered share count, if any
  final double? cost; // entered dollar cost, if any
  final DateTime? sellDate; // null = still held

  const Lot({required this.buyDate, this.shares, this.cost, this.sellDate});

  bool get isClosed => sellDate != null;

  /// Initial share count given the buy-date [marketPrice]. Uses the entered
  /// shares if present, else cost ÷ price (guards a zero/negative price).
  double initialShares(double marketPrice) =>
      shares ?? (marketPrice > 0 ? (cost ?? 0) / marketPrice : 0);

  /// Dollars invested given the buy-date [marketPrice]. Uses the entered cost
  /// if present, else shares × price.
  double initialCost(double marketPrice) => cost ?? (shares ?? 0) * marketPrice;

  Map<String, dynamic> toJson() => {
    'buyDate': buyDate.toUtc().millisecondsSinceEpoch,
    if (shares != null) 'shares': shares,
    if (cost != null) 'cost': cost,
    if (sellDate != null) 'sellDate': sellDate!.toUtc().millisecondsSinceEpoch,
  };

  factory Lot.fromJson(Map<String, dynamic> j) {
    // Migrate the old {mode, amount} shape to {shares|cost}.
    double? shares = (j['shares'] as num?)?.toDouble();
    double? cost = (j['cost'] as num?)?.toDouble();
    if (shares == null && cost == null && j['amount'] != null) {
      final amount = (j['amount'] as num).toDouble();
      if (j['mode'] == 'dollars') {
        cost = amount;
      } else {
        shares = amount;
      }
    }
    return Lot(
      buyDate: DateTime.fromMillisecondsSinceEpoch(
        (j['buyDate'] as num).toInt(),
        isUtc: true,
      ),
      shares: shares,
      cost: cost,
      sellDate: j['sellDate'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (j['sellDate'] as num).toInt(),
              isUtc: true,
            ),
    );
  }
}

/// Per-lot economics under the broker-DRIP + return-of-capital model. Only
/// distributions on or after [buyDate] count toward this lot; income scales by
/// the lot's *initial* share count [initialShares] (Model A — keeps the single
/// default lot identical to the original per-share math and verifiable by hand).
class LotResult {
  final DateTime buyDate;
  final double initialShares; // S
  final double buyPrice; // price resolved on buyDate
  final double finalShares; // S × Π(1 + d/P) over this lot's distributions
  final double cost; // S × buyPrice (dollars invested)
  final double distributions; // gross $ paid while held = S × Σ d (reinvested)
  final double incomeAmount; // taxable income (S × Σ d·(1−roc))
  final double taxThisYear; // incomeAmount × combined rate
  // Position value now: open lots = finalShares × currentPrice; closed lots =
  // proceeds = finalShares × sellPrice (locked in on the sell date).
  final double nav;
  final double costBasis; // cost + reinvested income (ROC cancels — see memory)
  final double gl; // nav − costBasis (unrealized if open, realized if closed)
  // Sale, when closed. null sellDate ⇒ still held.
  final DateTime? sellDate;
  final double? sellPrice;

  bool get isClosed => sellDate != null;

  const LotResult({
    required this.buyDate,
    required this.initialShares,
    required this.buyPrice,
    required this.finalShares,
    required this.cost,
    required this.distributions,
    required this.incomeAmount,
    required this.taxThisYear,
    required this.nav,
    required this.costBasis,
    required this.gl,
    this.sellDate,
    this.sellPrice,
  });
}

class YieldResult {
  final String ticker;
  final double currentPrice;
  final double sumDistributions;
  // Advertised yield: sum(dist) / current_price.
  final double grossYield;
  // Share growth from a real broker DRIP of the full gross distribution,
  // starting from 1 share: prod(1 + d_t / P_t) - 1. dripShares = this + 1.
  final double compoundedGrossYield;
  final double dripShares;

  // Position economics under the broker-DRIP + return-of-capital model.
  // startPrice ≈ price one year ago (first valid close); combinedRate is the
  // total tax fraction; rocPct is the share of distributions that is return of
  // capital (untaxed now, but it lowers basis — see roc-cost-basis-and-gl memory).
  final double startPrice;
  final double combinedRate;
  final double rocPct;
  // incomeAmount = taxable income portion of distributions = sum * (1 - roc).
  final double incomeAmount;
  // Tax owed this year, on the income portion only.
  final double taxThisYear;
  // nav = dripShares * currentPrice (what the position is worth now).
  final double nav;
  // Tax basis = original cost + reinvested INCOME. Reinvesting the ROC portion
  // adds basis but ROC also lowers basis by the same amount, so they cancel:
  // costBasis = startPrice + incomeAmount.
  final double costBasis;
  // Capital gain/loss, partitioned: unrealizedGL is the open lots' paper gain
  // (nav − basis, taxed only when sold); realizedGL is the closed lots' booked
  // gain (proceeds − basis). Together they equal nav − costBasis.
  final double unrealizedGL;
  final double realizedGL;
  // ROC-aware after-tax distribution yield: (sum - taxThisYear) / currentPrice.
  final double afterTaxYieldRoc;
  // Total return on the original cost, before and after this year's tax.
  final double totalReturnBeforeTax;
  final double totalReturnAfterTax;

  // ─── Lots. One entry per purchase; the aggregate dollar fields above
  //     (nav/costBasis/incomeAmount/taxThisYear/unrealizedGL) are the sums over
  //     these. For a single default lot they collapse to the original per-share
  //     numbers, so startPrice/dripShares/costBasis keep their old meaning.
  final List<LotResult> lots;
  // Total dollars invested across all lots = Σ lot.cost. The cost denominator
  // for the portfolio total return (the multi-lot analog of startPrice).
  final double totalCost;
  // Taxable income for exactly ONE share over all distributions (Σ d·(1−roc)),
  // independent of lots. Powers the per-share yield lines and the
  // Distributions-tab ROC split, which stay per-share concepts.
  final double perShareIncome;
  // Gross distributions actually received (and DRIP-reinvested) across all
  // lots, in dollars = Σ lot.distributions.
  final double distributionsReceived;

  // True when no explicit lots were entered — the result is the original
  // "1 share a year ago" hypothetical, so the UI shows the per-share TTM
  // statement + reference grid. With real lots it shows a by-lot portfolio view.
  final bool isDefaultLot;

  final List<DistributionEntry> distributions;
  final List<PriceBar> priceBars;
  final bool qualifies;
  final String? reason;

  const YieldResult({
    required this.ticker,
    required this.currentPrice,
    required this.sumDistributions,
    required this.grossYield,
    required this.compoundedGrossYield,
    required this.dripShares,
    required this.startPrice,
    required this.combinedRate,
    required this.rocPct,
    required this.incomeAmount,
    required this.taxThisYear,
    required this.nav,
    required this.costBasis,
    required this.unrealizedGL,
    required this.realizedGL,
    required this.afterTaxYieldRoc,
    required this.totalReturnBeforeTax,
    required this.totalReturnAfterTax,
    required this.lots,
    required this.totalCost,
    required this.perShareIncome,
    required this.distributionsReceived,
    required this.isDefaultLot,
    required this.distributions,
    required this.priceBars,
    required this.qualifies,
    this.reason,
  });

  factory YieldResult.doesNotQualify({
    required String ticker,
    required double currentPrice,
    required String reason,
    List<PriceBar> priceBars = const [],
  }) {
    return YieldResult(
      ticker: ticker,
      currentPrice: currentPrice,
      sumDistributions: 0,
      grossYield: 0,
      compoundedGrossYield: 0,
      dripShares: 1,
      startPrice: currentPrice,
      combinedRate: 0,
      rocPct: 0,
      incomeAmount: 0,
      taxThisYear: 0,
      nav: currentPrice,
      costBasis: currentPrice,
      unrealizedGL: 0,
      realizedGL: 0,
      afterTaxYieldRoc: 0,
      totalReturnBeforeTax: 0,
      totalReturnAfterTax: 0,
      lots: const [],
      totalCost: currentPrice,
      perShareIncome: 0,
      distributionsReceived: 0,
      isDefaultLot: true,
      distributions: const [],
      priceBars: priceBars,
      qualifies: false,
      reason: reason,
    );
  }
}

/// Pure-function yield math. No Flutter, no HTTP, no DateTime.now().
/// All inputs are explicit so this class is trivially testable.
class YieldMath {
  static YieldResult compute({
    required String ticker,
    required double currentPrice,
    required double federalPct,
    required double statePct,
    required double localPct,
    required List<DistributionEntry> distributions,
    required List<PriceBar> priceBars,
    double rocPct = 0,
    // One purchase per lot. null/empty → a single default lot (1 share bought at
    // the start of the window), which reproduces the original per-share math.
    List<Lot>? lots,
  }) {
    final sortedCloses = [...priceBars]
      ..sort((a, b) => a.date.compareTo(b.date));

    if (distributions.isEmpty) {
      return YieldResult.doesNotQualify(
        ticker: ticker,
        currentPrice: currentPrice,
        reason: 'no distributions in last 12 months',
        priceBars: sortedCloses,
      );
    }

    final combined = (federalPct + statePct + localPct) / 100.0;
    final ascDist = [...distributions]
      ..sort((a, b) => a.date.compareTo(b.date));

    // Per-share, ticker-level figures (independent of lots): the advertised
    // distribution total and the income portion under per-distribution ROC.
    double sum = 0;
    double perShareIncome = 0;
    for (final d in ascDist) {
      sum += d.amount;
      perShareIncome += d.amount * (1 - _rocFrac(d.rocPct ?? rocPct));
    }
    final grossYield = sum / currentPrice;

    // First valid close ≈ price one year ago; falls back to currentPrice if
    // every bar's close is null. Used as the default lot's buy price and the
    // single-lot reference grid's "start" column.
    double startPrice = currentPrice;
    for (final bar in sortedCloses) {
      final c = bar.close;
      if (c != null && c > 0) {
        startPrice = c;
        break;
      }
    }

    // No explicit lots → one default lot. Its buy date precedes every bar and
    // distribution (epoch 0), so priceAt resolves to startPrice and all
    // distributions count: the lot's economics equal the original 1-share path.
    final isDefaultLot = lots == null || lots.isEmpty;
    final effectiveLots = isDefaultLot
        ? [
            Lot(
              buyDate: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              shares: 1,
            ),
          ]
        : lots;

    final lotResults = [
      for (final lot in effectiveLots)
        _computeLot(lot, ascDist, sortedCloses, currentPrice, combined, rocPct),
    ];

    // Portfolio aggregates = sums of the per-lot dollar quantities. Capital
    // gain is split: open lots' paper gain (unrealized) vs closed lots' booked
    // gain (realized). Together they equal nav − costBasis.
    double totalCost = 0,
        totalInitialShares = 0,
        totalFinalShares = 0,
        distributionsReceived = 0,
        incomeAmount = 0,
        taxThisYear = 0,
        nav = 0,
        costBasis = 0,
        unrealizedGL = 0,
        realizedGL = 0;
    for (final l in lotResults) {
      totalCost += l.cost;
      totalInitialShares += l.initialShares;
      totalFinalShares += l.finalShares;
      distributionsReceived += l.distributions;
      incomeAmount += l.incomeAmount;
      taxThisYear += l.taxThisYear;
      nav += l.nav;
      costBasis += l.costBasis;
      if (l.isClosed) {
        realizedGL += l.gl;
      } else {
        unrealizedGL += l.gl;
      }
    }
    // dripShares = total shares now; growth is weighted by initial shares so the
    // single default lot (1 → finalShares) keeps its old "1.00 → X" meaning.
    final dripShares = totalFinalShares;
    final compoundedGrossYield =
        (totalInitialShares > 0 ? totalFinalShares / totalInitialShares : 1.0) -
        1;
    // The two yield lines stay per-share: deduct one share's worth of tax.
    final perShareTax = perShareIncome * combined;
    final afterTaxYieldRoc = (sum - perShareTax) / currentPrice;
    final totalReturnBeforeTax = totalCost > 0
        ? (nav - totalCost) / totalCost
        : 0.0;
    final totalReturnAfterTax = totalCost > 0
        ? (nav - taxThisYear - totalCost) / totalCost
        : 0.0;

    final descDist = [...distributions]
      ..sort((a, b) => b.date.compareTo(a.date));

    return YieldResult(
      ticker: ticker,
      currentPrice: currentPrice,
      sumDistributions: sum,
      grossYield: grossYield,
      compoundedGrossYield: compoundedGrossYield,
      dripShares: dripShares,
      startPrice: startPrice,
      combinedRate: combined,
      rocPct: rocPct,
      incomeAmount: incomeAmount,
      taxThisYear: taxThisYear,
      nav: nav,
      costBasis: costBasis,
      unrealizedGL: unrealizedGL,
      realizedGL: realizedGL,
      afterTaxYieldRoc: afterTaxYieldRoc,
      totalReturnBeforeTax: totalReturnBeforeTax,
      totalReturnAfterTax: totalReturnAfterTax,
      lots: lotResults,
      totalCost: totalCost,
      perShareIncome: perShareIncome,
      distributionsReceived: distributionsReceived,
      isDefaultLot: isDefaultLot,
      distributions: descDist,
      priceBars: sortedCloses,
      qualifies: true,
    );
  }

  /// Return-of-capital fraction in [0, 1] from a percentage (clamped).
  static double _rocFrac(double pct) => (pct / 100.0).clamp(0.0, 1.0);

  /// Economics for one lot: DRIP its initial shares forward over the
  /// distributions while it is held — on or after [Lot.buyDate], and on or
  /// before [Lot.sellDate] for a closed lot (Model A — income scales by the
  /// initial share count, not the growing DRIP count). A closed lot is valued
  /// at the sell-date price (proceeds), booking a realized gain; an open lot is
  /// valued at [currentPrice]. [defaultRoc] is the global ROC % applied to any
  /// distribution without its own override.
  static LotResult _computeLot(
    Lot lot,
    List<DistributionEntry> ascDist,
    List<PriceBar> sortedCloses,
    double currentPrice,
    double combined,
    double defaultRoc,
  ) {
    final marketBuyPrice = priceAt(lot.buyDate, sortedCloses) ?? currentPrice;
    final s = lot.initialShares(marketBuyPrice);
    final cost = lot.initialCost(marketBuyPrice);
    // Effective per-share basis: cost ÷ shares (when the user entered both this
    // can differ from the market close — that's their actual fill).
    final buyPrice = s > 0 ? cost / s : marketBuyPrice;
    final sellDate = lot.sellDate;
    final sellPrice = sellDate == null
        ? null
        : (priceAt(sellDate, sortedCloses) ?? currentPrice);

    double factor = 1;
    double distPerShare = 0;
    double incomePerShare = 0;
    for (final d in ascDist) {
      if (d.date.isBefore(lot.buyDate)) continue;
      if (sellDate != null && d.date.isAfter(sellDate)) continue;
      final priceAtDiv = priceAt(d.date, sortedCloses) ?? currentPrice;
      factor *= 1 + d.amount / priceAtDiv;
      distPerShare += d.amount;
      incomePerShare += d.amount * (1 - _rocFrac(d.rocPct ?? defaultRoc));
    }

    final finalShares = s * factor;
    final incomeAmount = s * incomePerShare;
    // Closed lots lock in their value at the sell price; open lots float with
    // the current price.
    final nav = finalShares * (sellPrice ?? currentPrice);
    final costBasis = cost + incomeAmount;
    return LotResult(
      buyDate: lot.buyDate,
      initialShares: s,
      buyPrice: buyPrice,
      finalShares: finalShares,
      cost: cost,
      distributions: s * distPerShare,
      incomeAmount: incomeAmount,
      taxThisYear: incomeAmount * combined,
      nav: nav,
      costBasis: costBasis,
      gl: nav - costBasis,
      sellDate: sellDate,
      sellPrice: sellPrice,
    );
  }

  /// Index of the latest bar whose date is on or before [divDate].
  /// Returns -1 if [bars] is empty or every bar starts after [divDate].
  @visibleForTesting
  static int barIndexAt(DateTime divDate, List<PriceBar> bars) {
    if (bars.isEmpty) return -1;
    int idx = -1;
    for (int i = 0; i < bars.length; i++) {
      if (!bars[i].date.isAfter(divDate)) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// Close of the bar identified by [barIndexAt], walking backwards if that
  /// bar's close is null. If the date is before all bars, falls back to the
  /// first available bar's close. Returns null only when no bar in the entire
  /// list has a non-null close.
  @visibleForTesting
  static double? priceAt(DateTime divDate, List<PriceBar> bars) {
    if (bars.isEmpty) return null;
    final idx = barIndexAt(divDate, bars);
    final start = idx >= 0 ? idx : 0;
    for (int j = start; j >= 0; j--) {
      final v = bars[j].close;
      if (v != null) return v;
    }
    for (int j = start + 1; j < bars.length; j++) {
      final v = bars[j].close;
      if (v != null) return v;
    }
    return null;
  }
}

/// Parses a Yahoo Finance chart JSON [responseBody] into a [YieldResult].
///
/// Pure: no network and no clock, so it is exercised directly in tests with
/// canned payloads. Throws a human-readable [String] on an API error envelope,
/// empty results, or a missing current price.
YieldResult parseYahooChart(
  String responseBody, {
  required String ticker,
  required double federalPct,
  required double statePct,
  required double localPct,
  double rocPct = 0,
  // Per-distribution ROC overrides keyed by the Yahoo dividend epoch (seconds).
  // A matched entry overrides the global [rocPct] for that payout.
  Map<int, double>? rocByDivEpoch,
  // One purchase per lot; null/empty → the single default lot.
  List<Lot>? lots,
}) {
  final body = json.decode(responseBody) as Map<String, dynamic>;
  final chart = body['chart'] as Map<String, dynamic>?;
  final err = chart?['error'];
  if (err != null) {
    throw err is Map ? (err['description'] ?? err.toString()) : err.toString();
  }
  final results = chart?['result'] as List<dynamic>?;
  if (results == null || results.isEmpty) {
    throw 'No data for "$ticker".';
  }
  final r0 = results.first as Map<String, dynamic>;
  final meta = r0['meta'] as Map<String, dynamic>?;
  final price = (meta?['regularMarketPrice'] as num?)?.toDouble();
  if (price == null) {
    throw 'Missing current price for "$ticker".';
  }

  final timestamps =
      (r0['timestamp'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList() ??
      const <int>[];
  final closes =
      ((r0['indicators']?['quote'] as List<dynamic>?)?.first
              as Map<String, dynamic>?)?['close']
          as List<dynamic>? ??
      const [];

  final priceBars = <PriceBar>[
    for (int i = 0; i < timestamps.length; i++)
      PriceBar(
        date: DateTime.fromMillisecondsSinceEpoch(
          timestamps[i] * 1000,
          isUtc: true,
        ),
        close: (i < closes.length && closes[i] is num)
            ? (closes[i] as num).toDouble()
            : null,
      ),
  ];

  final events = r0['events'] as Map<String, dynamic>?;
  final dividends = events?['dividends'] as Map<String, dynamic>?;
  final distributionList = <DistributionEntry>[];
  if (dividends != null) {
    for (final entry in dividends.values) {
      final m = entry as Map<String, dynamic>;
      final amt = (m['amount'] as num?)?.toDouble();
      final divTs = (m['date'] as num?)?.toInt();
      if (amt == null || divTs == null) continue;
      distributionList.add(
        DistributionEntry(
          date: DateTime.fromMillisecondsSinceEpoch(divTs * 1000, isUtc: true),
          amount: amt,
          rocPct: rocByDivEpoch?[divTs],
        ),
      );
    }
  }

  return YieldMath.compute(
    ticker: ticker,
    currentPrice: price,
    federalPct: federalPct,
    statePct: statePct,
    localPct: localPct,
    distributions: distributionList,
    priceBars: priceBars,
    rocPct: rocPct,
    lots: lots,
  );
}

/// Smallest Yahoo `range` value that covers [earliestBuy] back from [now].
/// The chart endpoint only accepts these discrete spans, so we round up. Pure
/// (takes [now]) so it's unit-testable without the clock.
String yahooRangeFor(DateTime earliestBuy, DateTime now) {
  final days = now.difference(earliestBuy).inDays;
  if (days <= 366) return '1y';
  if (days <= 731) return '2y';
  if (days <= 1827) return '5y';
  if (days <= 3653) return '10y';
  return 'max';
}

/// One self-test scenario for the Diagnostics tab: a labeled [YieldResult]
/// computed from synthetic data, used to sanity-check the lot math.
class DiagnosticScenario {
  final String label;
  final String detail;
  final YieldResult result;
  const DiagnosticScenario(this.label, this.detail, this.result);
}

/// Deterministic self-test scenarios computed from synthetic data anchored to
/// [now] (no network): a rising $10→$13 price over ~3 years with a fixed $0.25
/// monthly distribution. Covers the holding-period cases — no lots, a lot held
/// under a year, over a year, over two years, several lots, and a closed lot —
/// so the Diagnostics tab and the tests share exactly one source of truth. Pure
/// (takes [now]).
List<DiagnosticScenario> buildDiagnostics(DateTime now) {
  final today = DateTime.utc(now.year, now.month, now.day);
  const months = 37; // ~3 years of monthly bars
  final bars = <PriceBar>[
    for (int i = months - 1; i >= 0; i--)
      PriceBar(
        date: DateTime.utc(today.year, today.month - i, 1),
        close: double.parse(
          (10.0 + (months - 1 - i) * (3.0 / (months - 1))).toStringAsFixed(2),
        ),
      ),
  ];
  final dists = <DistributionEntry>[
    for (int i = months - 1; i >= 1; i--)
      DistributionEntry(
        date: DateTime.utc(today.year, today.month - i, 15),
        amount: 0.25,
      ),
  ];
  final price = bars.last.close!;
  DateTime ago(int m) => DateTime.utc(today.year, today.month - m, today.day);

  YieldResult run(List<Lot>? lots) => YieldMath.compute(
    ticker: 'DIAG',
    currentPrice: price,
    federalPct: 32,
    statePct: 5,
    localPct: 0,
    distributions: dists,
    priceBars: bars,
    rocPct: 50,
    lots: lots,
  );

  return [
    DiagnosticScenario('No lots', '1 share, ~1y default (TTM view)', run(null)),
    DiagnosticScenario(
      '1 lot · 3 months',
      'held under 12 months · 100 sh',
      run([Lot(buyDate: ago(3), shares: 100)]),
    ),
    DiagnosticScenario(
      '1 lot · 18 months',
      'held over 12 months · 100 sh',
      run([Lot(buyDate: ago(18), shares: 100)]),
    ),
    DiagnosticScenario(
      '1 lot · 30 months',
      'held over 2 years · 100 sh',
      run([Lot(buyDate: ago(30), shares: 100)]),
    ),
    DiagnosticScenario(
      'Multiple lots',
      '3 lots bought 3 / 18 / 30 months ago',
      run([
        Lot(buyDate: ago(3), shares: 100),
        Lot(buyDate: ago(18), shares: 100),
        Lot(buyDate: ago(30), shares: 100),
      ]),
    ),
    DiagnosticScenario(
      'Closed lot',
      'bought 18 mo ago, sold 6 mo ago',
      run([Lot(buyDate: ago(18), shares: 100, sellDate: ago(6))]),
    ),
  ];
}

class YieldScreen extends StatefulWidget {
  /// Optional HTTP client seam. Production leaves this null and a one-shot
  /// client is created per request; tests inject a mock to drive the
  /// Calculate → parse → render flow without real network access.
  final http.Client? client;

  const YieldScreen({super.key, this.client});

  @override
  State<YieldScreen> createState() => _YieldScreenState();
}

class _YieldScreenState extends State<YieldScreen> with WidgetsBindingObserver {
  final _tickerCtrl = TextEditingController();
  final _federalCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _localCtrl = TextEditingController(text: '0');
  final _rocCtrl = TextEditingController(text: '71');
  final _scrollCtrl = ScrollController();

  bool _loading = false;
  String? _error;
  YieldResult? _result;
  // When the shown result was fetched (device clock). Drives the "As of" stamp
  // and the stale-on-a-new-day check; null whenever no result is displayed.
  DateTime? _resultFetchedAt;

  // Purchases the user entered. Empty = the single default lot (1 share, ~1 year
  // ago), preserving the original behavior with zero migration for old users.
  List<Lot> _lots = [];
  // Per-distribution ROC % overrides keyed by the Yahoo dividend epoch (seconds).
  // Set from the Distributions tab; survives re-fetch because the key is stable.
  Map<int, double> _rocOverrides = {};

  // The ticker whose bundled ROC we last auto-filled into the ROC field, so we
  // only re-apply when the ticker actually changes to a different known fund.
  String? _rocSourceTicker;

  static const _kTicker = 'last_ticker';
  static const _kFederal = 'rate_federal';
  static const _kState = 'rate_state';
  static const _kLocal = 'rate_local';
  static const _kRoc = 'rate_roc';
  static const _kLots = 'lots';
  static const _kRocOverrides = 'roc_overrides';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedInputs();
    for (final c in [
      _tickerCtrl,
      _federalCtrl,
      _stateCtrl,
      _localCtrl,
      _rocCtrl,
    ]) {
      c.addListener(_clearStaleResult);
    }
    // Entering a known YieldMax ticker auto-fills its ROC % from the bundled
    // 19a-1 data; the ticker/ROC fields also drive the source caption, so keep
    // the form repainting as they change.
    _tickerCtrl.addListener(_maybeAutofillRoc);
    _tickerCtrl.addListener(_rebuildForCaption);
    _rocCtrl.addListener(_rebuildForCaption);
  }

  void _rebuildForCaption() {
    if (mounted) setState(() {});
  }

  // When the ticker changes to a known fund, set the ROC % field to that fund's
  // trailing return-of-capital. Only fires on a genuine ticker change, so a
  // user's manual ROC edit isn't clobbered while they keep the same ticker.
  void _maybeAutofillRoc() {
    final tkr = _tickerCtrl.text.trim().toUpperCase();
    if (tkr == _rocSourceTicker) return;
    final roc = rocForTicker(tkr);
    if (roc == null) {
      _rocSourceTicker = null;
      return;
    }
    _rocSourceTicker = tkr;
    _rocCtrl.text = _fmtRoc(roc);
  }

  // Trim a trailing ".0" so "71.0" shows as "71" but "70.1" stays.
  static String _fmtRoc(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  // If the app is resumed on a later calendar day, the shown result's TTM
  // window has shifted, so silently re-run against the same inputs to refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _result != null &&
        !_loading &&
        _resultFetchedAt != null &&
        isStale(_resultFetchedAt!, DateTime.now())) {
      _calculate();
    }
  }

  // Editing any input invalidates a shown result, so drop it — the card must
  // only ever display numbers that match the current inputs.
  void _clearStaleResult() {
    if (_result != null || _error != null) {
      setState(() {
        _result = null;
        _error = null;
        _resultFetchedAt = null;
      });
    }
  }

  Future<void> _loadSavedInputs() async {
    final prefs = await SharedPreferences.getInstance();
    // Corrupt JSON must never crash boot — fall back to the defaults.
    List<Lot> lots = [];
    Map<int, double> overrides = {};
    try {
      final raw = prefs.getString(_kLots);
      if (raw != null) {
        lots = [
          for (final e in json.decode(raw) as List)
            Lot.fromJson(e as Map<String, dynamic>),
        ];
      }
    } catch (_) {
      lots = [];
    }
    try {
      final raw = prefs.getString(_kRocOverrides);
      if (raw != null) {
        overrides = (json.decode(raw) as Map<String, dynamic>).map(
          (k, v) => MapEntry(int.parse(k), (v as num).toDouble()),
        );
      }
    } catch (_) {
      overrides = {};
    }
    setState(() {
      _tickerCtrl.text = prefs.getString(_kTicker) ?? '';
      _federalCtrl.text = prefs.getString(_kFederal) ?? '';
      _stateCtrl.text = prefs.getString(_kState) ?? '';
      _localCtrl.text = prefs.getString(_kLocal) ?? '0';
      _rocCtrl.text = prefs.getString(_kRoc) ?? '71';
      _lots = lots;
      _rocOverrides = overrides;
    });
  }

  Future<void> _saveInputs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTicker, _tickerCtrl.text.trim().toUpperCase());
    await prefs.setString(_kFederal, _federalCtrl.text);
    await prefs.setString(_kState, _stateCtrl.text);
    await prefs.setString(_kLocal, _localCtrl.text);
    await prefs.setString(_kRoc, _rocCtrl.text);
    await prefs.setString(
      _kLots,
      json.encode([for (final l in _lots) l.toJson()]),
    );
    await prefs.setString(
      _kRocOverrides,
      json.encode(_rocOverrides.map((k, v) => MapEntry(k.toString(), v))),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickerCtrl.dispose();
    _federalCtrl.dispose();
    _stateCtrl.dispose();
    _localCtrl.dispose();
    _rocCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // Select the field's entire contents so the next keystroke replaces them.
  // Matches the desktop "click to type-over" pattern users expect on numeric
  // and ticker fields. Posting to the next frame lets the framework finish
  // its own focus/selection bookkeeping before we override.
  void _selectAll(TextEditingController c) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.text.isEmpty) return;
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
  }

  // null when no explicit lots → compute() uses the single default lot.
  List<Lot>? _activeLots() => _lots.isEmpty ? null : _lots;

  // Yahoo dividend epoch (seconds) — the stable key for a ROC override.
  int _epochOf(DateTime d) => d.toUtc().millisecondsSinceEpoch ~/ 1000;

  // Mutate the lots and persist. A lot change can require a wider fetch range
  // (an older buy date needs more history), so the shown card is dropped — the
  // user re-taps Calculate, which refetches with the right range.
  void _mutateLots(void Function() change) {
    setState(() {
      change();
      _result = null;
      _error = null;
      _resultFetchedAt = null;
    });
    _saveInputs();
  }

  // Set or clear a per-distribution ROC override. Unlike a lot change, this
  // needs no new data, so the shown result recomputes in place (live).
  void _setRocOverride(int epoch, double? pct) {
    setState(() {
      if (pct == null) {
        _rocOverrides.remove(epoch);
      } else {
        _rocOverrides[epoch] = pct;
      }
      _recomputeInPlace();
    });
    _saveInputs();
  }

  // Re-run the pure math on the already-fetched bars/distributions with the
  // current lots, tax rates, and ROC overrides — no network. Caller wraps this
  // in setState. No-op until a qualifying result exists.
  void _recomputeInPlace() {
    final r = _result;
    if (r == null || !r.qualifies) return;
    final fed = double.tryParse(_federalCtrl.text.trim()) ?? 0;
    final state = double.tryParse(_stateCtrl.text.trim()) ?? 0;
    final localText = _localCtrl.text.trim();
    final local = double.tryParse(localText.isEmpty ? '0' : localText) ?? 0;
    final rocText = _rocCtrl.text.trim();
    final roc = double.tryParse(rocText.isEmpty ? '0' : rocText) ?? 0;
    _result = YieldMath.compute(
      ticker: r.ticker,
      currentPrice: r.currentPrice,
      federalPct: fed,
      statePct: state,
      localPct: local,
      distributions: [
        for (final d in r.distributions)
          DistributionEntry(
            date: d.date,
            amount: d.amount,
            rocPct: _rocOverrides[_epochOf(d.date)],
          ),
      ],
      priceBars: r.priceBars,
      rocPct: roc,
      lots: _activeLots(),
    );
  }

  Future<void> _calculate() async {
    // Dismiss the keyboard the moment the user commits — otherwise it
    // covers the result card on smaller phones.
    FocusManager.instance.primaryFocus?.unfocus();
    final ticker = _tickerCtrl.text.trim().toUpperCase();
    if (ticker.isEmpty) {
      setState(() => _error = 'Enter a ticker.');
      return;
    }
    final fed = double.tryParse(_federalCtrl.text.trim());
    final state = double.tryParse(_stateCtrl.text.trim());
    final localText = _localCtrl.text.trim();
    final local = double.tryParse(localText.isEmpty ? '0' : localText);
    final rocText = _rocCtrl.text.trim();
    final roc = double.tryParse(rocText.isEmpty ? '0' : rocText);
    if (fed == null || state == null || local == null) {
      setState(() => _error = 'Tax rates must be numeric (e.g. 32 for 32%).');
      return;
    }
    if (roc == null || roc < 0 || roc > 100) {
      setState(() => _error = 'Return of capital % must be between 0 and 100.');
      return;
    }
    final now = DateTime.now();
    for (final lot in _lots) {
      final hasShares = lot.shares != null;
      final hasCost = lot.cost != null;
      if (!hasShares && !hasCost) {
        setState(() => _error = 'Each lot needs a share count or a cost.');
        return;
      }
      if ((hasShares && lot.shares! <= 0) || (hasCost && lot.cost! <= 0)) {
        setState(() => _error = 'Lot shares and cost must be positive.');
        return;
      }
      if (lot.buyDate.isAfter(now)) {
        setState(() => _error = 'A lot buy date cannot be in the future.');
        return;
      }
      final sell = lot.sellDate;
      if (sell != null) {
        if (sell.isAfter(now)) {
          setState(() => _error = 'A lot sell date cannot be in the future.');
          return;
        }
        if (sell.isBefore(lot.buyDate)) {
          setState(
            () => _error = 'A lot sell date must be after its buy date.',
          );
          return;
        }
      }
    }

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _resultFetchedAt = null;
    });

    await _saveInputs();

    try {
      final result = await _fetchYield(
        ticker: ticker,
        federalPct: fed,
        statePct: state,
        localPct: local,
        rocPct: roc,
      );
      setState(() {
        _result = result;
        _resultFetchedAt = DateTime.now();
        _loading = false;
      });
      // Slide the inputs up so the full result card (through the reference
      // grid) is in view without the user scrolling.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
        );
      });
    } catch (e) {
      setState(() {
        _error = 'Lookup failed: $e';
        _loading = false;
      });
    }
  }

  Future<YieldResult> _fetchYield({
    required String ticker,
    required double federalPct,
    required double statePct,
    required double localPct,
    required double rocPct,
  }) async {
    // Fetch enough history to cover the earliest lot; no lots → the default
    // 1-year window (the original behavior).
    final now = DateTime.now();
    final earliestBuy = _lots.isEmpty
        ? now.subtract(const Duration(days: 365))
        : _lots.map((l) => l.buyDate).reduce((a, b) => a.isBefore(b) ? a : b);
    final range = yahooRangeFor(earliestBuy, now);
    final uri = Uri.parse(
      '$yahooBase/v8/finance/chart/$ticker?interval=1d&range=$range&events=div',
    );
    final client = widget.client ?? http.Client();
    try {
      final resp = await client.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
        },
      );
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      return parseYahooChart(
        resp.body,
        ticker: ticker,
        federalPct: federalPct,
        statePct: statePct,
        localPct: localPct,
        rocPct: rocPct,
        rocByDivEpoch: _rocOverrides,
        lots: _activeLots(),
      );
    } finally {
      // Only dispose clients we created; never close an injected one.
      if (widget.client == null) client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('TrueYield'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              Tab(text: 'Calculate'),
              Tab(text: 'Distributions'),
              Tab(text: 'Prices'),
              Tab(text: 'Diagnostics'),
              Tab(text: 'Info'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildCalculateTab(context),
              _DistributionsTab(
                result: _result,
                rocOverrides: _rocOverrides,
                defaultRoc: double.tryParse(_rocCtrl.text.trim()) ?? 0,
                onRocChanged: _setRocOverride,
              ),
              _PricesTab(result: _result),
              const _DiagnosticsTab(),
              const _InfoTab(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalculateTab(BuildContext context) {
    const fieldDecoration = InputDecoration(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    );
    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _tickerCtrl,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Ticker',
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  onTap: () => _selectAll(_tickerCtrl),
                  inputFormatters: [
                    TextInputFormatter.withFunction((oldVal, newVal) {
                      return newVal.copyWith(text: newVal.text.toUpperCase());
                    }),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _rocCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Return of capital %',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_rocCtrl),
                ),
              ),
            ],
          ),
          _buildRocSourceCaption(context),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _federalCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(labelText: 'Federal %'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_federalCtrl),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _stateCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(labelText: 'State %'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_stateCtrl),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _localCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(labelText: 'Local %'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_localCtrl),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildLotsSection(context),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _loading ? null : _calculate,
              child: _loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text(
                      'Calculate',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              margin: EdgeInsets.zero,
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!),
              ),
            ),
          if (_result != null)
            _ResultCard(result: _result!, fetchedAt: _resultFetchedAt),
        ],
      ),
    );
  }

  // Caption under the ROC field for a recognized YieldMax fund: shows the
  // bundled 19a-1 source when the field matches, or a one-tap reset when the
  // user has overridden it. Nothing for unknown tickers.
  Widget _buildRocSourceCaption(BuildContext context) {
    final tkr = _tickerCtrl.text.trim().toUpperCase();
    final roc = rocForTicker(tkr);
    if (roc == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final current = double.tryParse(_rocCtrl.text.trim());
    final matches = current != null && (current - roc).abs() < 0.05;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: matches
          ? Text(
              'ROC auto-filled from $tkr’s 19a-1 notices '
              '(${_fmtRoc(roc)}%, as of $kRocDataAsOf).',
              style: muted,
            )
          : InkWell(
              onTap: () {
                _rocSourceTicker = tkr;
                _rocCtrl.text = _fmtRoc(roc);
              },
              child: Text.rich(
                TextSpan(
                  style: muted,
                  children: [
                    TextSpan(text: '$tkr’s 19a-1 ROC is ${_fmtRoc(roc)}% — '),
                    TextSpan(
                      text: 'reset',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // Lots editor: a card listing each purchase (buy date + size). Empty = the
  // implicit default lot (1 share, ~1 year ago), so the original single-share
  // flow needs no setup. Adding lots turns the result into a portfolio.
  Widget _buildLotsSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Lots',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _mutateLots(() {
                    // Seed a new lot ~1 year ago, 100 shares (a sensible start
                    // the user edits — they can add a cost too).
                    final now = DateTime.now();
                    _lots.add(
                      Lot(
                        buyDate: DateTime.utc(now.year - 1, now.month, now.day),
                        shares: 100,
                      ),
                    );
                  }),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add lot'),
                ),
              ],
            ),
            if (_lots.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  'Default: 1 share bought ~1 year ago. Add lots to track real '
                  'buy dates and amounts.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (int i = 0; i < _lots.length; i++)
                _LotRow(
                  key: ValueKey(i),
                  lot: _lots[i],
                  onChanged: (l) => _mutateLots(() => _lots[i] = l),
                  onRemove: () => _mutateLots(() => _lots.removeAt(i)),
                ),
          ],
        ),
      ),
    );
  }
}

// One editable purchase row: buy date, amount, and a shares/dollars toggle.
// Owns its amount controller (seeded once in initState) so parent rebuilds on
// each keystroke don't fight the user's cursor.
class _LotRow extends StatefulWidget {
  final Lot lot;
  final ValueChanged<Lot> onChanged;
  final VoidCallback onRemove;
  const _LotRow({
    super.key,
    required this.lot,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_LotRow> createState() => _LotRowState();
}

class _LotRowState extends State<_LotRow> {
  late final TextEditingController _sharesCtrl;
  late final TextEditingController _costCtrl;
  late final FocusNode _sharesFocus;
  late final FocusNode _costFocus;

  @override
  void initState() {
    super.initState();
    _sharesCtrl = TextEditingController(text: _fmt(widget.lot.shares));
    _costCtrl = TextEditingController(text: _fmt(widget.lot.cost));
    _sharesFocus = FocusNode();
    _costFocus = FocusNode();
  }

  // Rows are keyed by index, so removing a middle lot reuses this State for a
  // different lot. When that happens (and we're not mid-edit in a field), resync
  // it — but never disturb the user's active typing.
  @override
  void didUpdateWidget(_LotRow old) {
    super.didUpdateWidget(old);
    if (!_sharesFocus.hasFocus && widget.lot.shares != old.lot.shares) {
      final t = _fmt(widget.lot.shares);
      if (_sharesCtrl.text != t) _sharesCtrl.text = t;
    }
    if (!_costFocus.hasFocus && widget.lot.cost != old.lot.cost) {
      final t = _fmt(widget.lot.cost);
      if (_costCtrl.text != t) _costCtrl.text = t;
    }
  }

  // Trim a trailing ".0" so "100.0" shows as "100" but "12.5" stays; null → "".
  static String _fmt(double? v) => v == null
      ? ''
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString());

  @override
  void dispose() {
    _sharesFocus.dispose();
    _costFocus.dispose();
    _sharesCtrl.dispose();
    _costCtrl.dispose();
    super.dispose();
  }

  // Emit an edit. `keepSell: false` clears the sale; otherwise sellDate is
  // preserved (and dropped only if a new buy date lands after it).
  void _emit({
    DateTime? buyDate,
    double? shares,
    double? cost,
    bool sharesSet = false,
    bool costSet = false,
    DateTime? sellDate,
    bool keepSell = true,
  }) {
    final lot = widget.lot;
    final newBuy = buyDate ?? lot.buyDate;
    DateTime? sell = sellDate ?? (keepSell ? lot.sellDate : null);
    if (sell != null && sell.isBefore(newBuy)) sell = null;
    widget.onChanged(
      Lot(
        buyDate: newBuy,
        shares: sharesSet ? shares : lot.shares,
        cost: costSet ? cost : lot.cost,
        sellDate: sell,
      ),
    );
  }

  Future<void> _pickBuyDate() async {
    final now = DateTime.now();
    final initial = widget.lot.buyDate.isAfter(now) ? now : widget.lot.buyDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (picked == null) return;
    _emit(buyDate: DateTime.utc(picked.year, picked.month, picked.day));
  }

  Future<void> _pickSellDate() async {
    final lot = widget.lot;
    final now = DateTime.now();
    final initial = lot.sellDate ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(lot.buyDate) ? lot.buyDate : initial,
      firstDate: lot.buyDate,
      lastDate: now,
    );
    if (picked == null) return;
    _emit(sellDate: DateTime.utc(picked.year, picked.month, picked.day));
  }

  void _clearSell() => _emit(keepSell: false);

  Widget _numField(
    TextEditingController ctrl,
    FocusNode focus,
    String label, {
    String? prefix,
    required void Function(double?) onValue,
  }) {
    return TextField(
      controller: ctrl,
      focusNode: focus,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        prefixText: prefix,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (t) {
        final s = t.trim();
        onValue(s.isEmpty ? null : double.tryParse(s));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final lot = widget.lot;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickBuyDate,
                  icon: const Icon(Icons.event, size: 16),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                  ),
                  label: Text(
                    'Bought ${fmtDateHuman(lot.buyDate)}',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: widget.onRemove,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove lot',
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Shares and/or cost — enter whichever you have; both = your basis.
          Row(
            children: [
              Expanded(
                child: _numField(
                  _sharesCtrl,
                  _sharesFocus,
                  'Shares',
                  onValue: (v) => _emit(shares: v, sharesSet: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numField(
                  _costCtrl,
                  _costFocus,
                  'Cost',
                  prefix: '\$',
                  onValue: (v) => _emit(cost: v, costSet: true),
                ),
              ),
            ],
          ),
          // Sell row: held to today, or a sell date that books a realized gain.
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Row(
              children: [
                Text(
                  'Sold:',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _pickSellDate,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    lot.isClosed
                        ? fmtDateHuman(lot.sellDate!)
                        : 'Held to today',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (lot.isClosed)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: _clearSell,
                    icon: const Icon(Icons.close, size: 14),
                    tooltip: 'Clear sell date (hold)',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Diagnostics tab: runs the lot math on deterministic synthetic data across a
// range of holding periods so anyone can sanity-check it without a network call.
class _DiagnosticsTab extends StatelessWidget {
  const _DiagnosticsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scenarios = buildDiagnostics(DateTime.now());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Text('Diagnostics', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Self-test scenarios on synthetic data — a price rising \$10 → \$13 '
          'over ~3 years, a \$0.25 monthly distribution, tax 37%, ROC 50%. They '
          'sanity-check the lot math across holding periods (no network).',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final s in scenarios) _DiagnosticCard(scenario: s),
      ],
    );
  }
}

class _DiagnosticCard extends StatelessWidget {
  final DiagnosticScenario scenario;
  const _DiagnosticCard({required this.scenario});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = scenario.result;
    final initial = r.lots.fold<double>(0, (s, l) => s + l.initialShares);
    final tag = r.isDefaultLot
        ? 'Default'
        : '${r.lots.length} lot${r.lots.length == 1 ? '' : 's'}';

    Widget row(String k, String v, {Color? c}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            k,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            v,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: c,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    scenario.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tag,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              scenario.detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 18),
            row(
              'Total return after tax',
              _signedPct(r.totalReturnAfterTax),
              c: _signColor(r.totalReturnAfterTax),
            ),
            row('Cost → value', '${_money(r.totalCost)} → ${_money(r.nav)}'),
            row(
              'Shares',
              '${initial.toStringAsFixed(2)} → ${r.dripShares.toStringAsFixed(2)}',
            ),
            row('Distributions received', _money(r.distributionsReceived)),
            row('Income (taxable)', _signedMoney(r.incomeAmount), c: _gain),
            if (r.realizedGL != 0)
              row(
                'Realized G/L',
                _signedMoney(r.realizedGL),
                c: _signColor(r.realizedGL),
              ),
            row(
              'Unrealized G/L',
              _signedMoney(r.unrealizedGL),
              c: _signColor(r.unrealizedGL),
            ),
            row('Tax this year', _signedMoney(-r.taxThisYear), c: _loss),
          ],
        ),
      ),
    );
  }
}

// Info tab: a short user guide — what the app tells you, how to use it, and how
// to read each result line — plus disclaimers and About/links.
class _InfoTab extends StatelessWidget {
  const _InfoTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final section = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('TrueYield', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Know what a dividend stock or ETF actually pays you — after taxes, '
            'and after the share price moves.',
            style: TextStyle(color: muted),
          ),
          const Divider(height: 28),
          Text('How to use', style: section),
          const SizedBox(height: 6),
          const Text(
            '1.  Enter a ticker (e.g. YMAG, SCHD, JEPI).\n'
            '2.  Return of capital % — the portion of distributions not taxed '
            'this year. For many YieldMax funds it auto-fills from their recent '
            'Section 19a-1 notices when you type the ticker; otherwise it '
            'defaults to 71. Edit it anytime (tap “reset” to restore the '
            'fund’s value).\n'
            '3.  Enter your marginal tax rates — federal, state, local.\n'
            '4.  (Optional) Add lots — real buy dates with a share count and/or '
            'cost (enter both and that’s your exact basis). Give a lot a sell '
            'date and it books a realized gain; leave it blank '
            'to hold to today. No lots = one share bought a year ago.\n'
            '5.  Tap Calculate.',
          ),
          const Divider(height: 28),
          Text('Reading the result', style: section),
          const SizedBox(height: 10),
          const _InfoTerm(
            term: 'Total return after tax',
            desc:
                'The bottom line — what one share bought a year ago is worth now, '
                'net of this year’s tax: income and price change together.',
          ),
          const _InfoTerm(
            term: 'DRIP grew your shares',
            desc:
                'Distributions are reinvested (a broker DRIP), compounding your '
                'share count — e.g. 1.00 → 1.59.',
          ),
          const _InfoTerm(
            term: 'Income / Unrealized G/L / Tax this year',
            desc:
                'The three pieces that sum to the total: taxable income, the '
                'paper gain or loss on your shares, and the tax due now. With '
                'sold lots a Realized G/L line is added for gains booked at the '
                'sell price.',
          ),
          const _InfoTerm(
            term: 'Advertised vs After-tax yield',
            desc:
                'The headline distribution yield vs what you actually keep after '
                'tax — both measured on today’s price.',
          ),
          const _InfoTerm(
            term: 'Reference grid',
            desc:
                'The raw Price, Shares, Present Value, and Cost basis the math is '
                'built from — a year ago vs now.',
          ),
          const Divider(height: 28),
          Text('The other tabs', style: section),
          const SizedBox(height: 6),
          const Text(
            '•  Distributions — every payout in the last 12 months, split into '
            'return of capital vs taxable income.\n'
            '•  Prices — the daily closes behind the calculation.',
          ),
          const Divider(height: 28),
          Text('Disclaimers', style: section),
          const SizedBox(height: 6),
          const Text(
            '•  Not investment advice — figures are historical (trailing 12 '
            'months), not a forecast.\n'
            '•  US tax model: one combined marginal rate on the taxable (non-ROC) '
            'portion of distributions.\n'
            '•  Return of capital % is your assumption — set it from the '
            'fund’s latest Section 19a notice.\n'
            '•  Data is Yahoo Finance’s public, unofficial endpoint and can '
            'change without notice.',
          ),
          const Divider(height: 28),
          Text('About', style: section),
          const SizedBox(height: 8),
          const _AboutLink(
            label: 'Project & README',
            url: 'https://github.com/jimzucker/TrueYield#readme',
          ),
          const _AboutLink(
            label: 'License (Apache 2.0)',
            url: 'https://github.com/jimzucker/TrueYield/blob/main/LICENSE',
          ),
          const _AboutLink(
            label: 'Privacy policy',
            url: 'https://github.com/jimzucker/TrueYield/blob/main/PRIVACY.md',
          ),
          _AboutLink(
            icon: Icons.article_outlined,
            label: 'Open-source licenses',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'TrueYield',
              applicationLegalese: '© 2026 James A. Zucker · Apache-2.0',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '© 2026 James A. Zucker · Apache-2.0\n'
            'Not affiliated with Yahoo. Yahoo and Yahoo Finance are trademarks of '
            'their respective owners.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
      ),
    );
  }
}

class _InfoTerm extends StatelessWidget {
  final String term;
  final String desc;
  const _InfoTerm({required this.term, required this.desc});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            term,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutLink extends StatelessWidget {
  final String label;
  final String? url;
  final VoidCallback? onTap;
  final IconData icon;
  const _AboutLink({
    required this.label,
    this.url,
    this.onTap,
    this.icon = Icons.open_in_new,
  });

  Future<void> _launch() async {
    final u = url;
    if (u == null) return;
    try {
      await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort: ignore if no handler can open the link.
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap ?? _launch,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final YieldResult result;
  final DateTime? fetchedAt;
  const _ResultCard({required this.result, this.fetchedAt});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);

    if (!r.qualifies) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(r.ticker, style: theme.textTheme.headlineSmall),
                  _StatusChip(qualifies: false),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Current price'),
                  Text(
                    _money(r.currentPrice),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Does not qualify (${r.reason})',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final afterTaxValue = r.nav - r.taxThisYear;
    // No lots entered → the original "1 share a year ago" per-share/TTM view.
    // With real lots → a by-lot, dollar-denominated portfolio view.
    final defaultView = r.isDefaultLot;
    final totalInitialShares = r.lots.fold<double>(
      0,
      (s, l) => s + l.initialShares,
    );
    final lotCount = r.lots.length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (fetchedAt != null) ...[
              Text(
                'As of ${fmtStamp(fetchedAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
            ],
            // Header: per-share TTM total for the default hypothetical; the
            // actual dollars received (and reinvested) for a real portfolio.
            _StmtRow(
              label: defaultView
                  ? 'TTM distributions'
                  : 'Distributions received',
              sub: 'reinvested via DRIP',
              value: _money(
                defaultView ? r.sumDistributions : r.distributionsReceived,
              ),
              headline: true,
            ),
            const Divider(height: 28),

            // ─── BLUF: total return after tax, with the three components that
            //     sum to it nested beneath (income + G/L − tax).
            _StmtRow(
              label: 'Total return after tax',
              sub: defaultView
                  ? '${_money(r.startPrice)} → ${_money(afterTaxValue)} on your start'
                  : '${_money(r.totalCost)} → ${_money(afterTaxValue)} on your cost',
              value: _signedPct(r.totalReturnAfterTax),
              valueColor: _signColor(r.totalReturnAfterTax),
              headline: true,
            ),
            const SizedBox(height: 8),
            // DRIP benefit memo — not a summed component (it's already baked
            // into Income + G/L), so it shows share growth, not $.
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                defaultView
                    ? 'DRIP grew your shares 1.00 → '
                          '${r.dripShares.toStringAsFixed(2)} '
                          '(+${(r.compoundedGrossYield * 100).toStringAsFixed(0)}%)'
                    : 'DRIP grew your shares ${totalInitialShares.toStringAsFixed(2)} → '
                          '${r.dripShares.toStringAsFixed(2)} '
                          'across $lotCount ${lotCount == 1 ? 'lot' : 'lots'} '
                          '(+${(r.compoundedGrossYield * 100).toStringAsFixed(0)}%)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _StmtRow(
              label: 'Income (taxable)',
              sub: defaultView
                  ? '${_money(r.sumDistributions)} × '
                        '${(100 - r.rocPct).toStringAsFixed(0)}% (1−ROC)'
                  : 'taxable part of ${_money(r.distributionsReceived)} received',
              value: _signedMoney(r.incomeAmount),
              valueColor: _gain,
              nested: true,
            ),
            if (r.realizedGL != 0)
              _StmtRow(
                label: 'Realized G/L',
                sub: 'booked on sold lots',
                value: _signedMoney(r.realizedGL),
                valueColor: _signColor(r.realizedGL),
                nested: true,
              ),
            if (r.unrealizedGL != 0 || r.realizedGL == 0)
              _StmtRow(
                label: 'Unrealized G/L',
                sub: r.realizedGL != 0
                    ? 'paper gain on lots still held'
                    : '${_money(r.nav)} value − ${_money(r.costBasis)} basis',
                value: _signedMoney(r.unrealizedGL),
                valueColor: _signColor(r.unrealizedGL),
                nested: true,
              ),
            _StmtRow(
              label: 'Tax this year',
              sub:
                  '${(r.combinedRate * 100).toStringAsFixed(0)}% on the '
                  '${_money(r.incomeAmount)} income',
              value: _signedMoney(-r.taxThisYear),
              valueColor: _loss,
              nested: true,
            ),
            const Divider(height: 28),

            // The per-share yields (denominator = current price) are a
            // single-share TTM concept — only meaningful for the default view.
            if (defaultView) ...[
              _StmtRow(
                label: 'Advertised yield',
                sub:
                    '${_money(r.sumDistributions)} ÷ ${_money(r.currentPrice)}',
                value: _pctPlain(r.grossYield),
              ),
              const SizedBox(height: 8),
              _StmtRow(
                label: 'After-tax yield',
                sub:
                    'kept ${_money(r.sumDistributions - r.perShareIncome * r.combinedRate)} ÷ '
                    '${_money(r.currentPrice)}',
                value: _pctPlain(r.afterTaxYieldRoc),
              ),
              const Divider(height: 28),
            ],

            if (defaultView)
              _ReferenceGrid(result: r)
            else
              _PortfolioGrid(result: r),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool qualifies;
  const _StatusChip({required this.qualifies});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOk = qualifies;
    final bg = isOk
        ? Colors.green.withValues(alpha: 0.18)
        : scheme.errorContainer;
    final fg = isOk ? Colors.greenAccent.shade400 : scheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isOk ? 'Qualifies' : 'Does not qualify',
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

// One line of the result statement: a label (+ optional explanatory sub) on the
// left and a right-aligned value. `headline` renders the BLUF total return big;
// `nested` indents the components that sum to it.
class _StmtRow extends StatelessWidget {
  final String label;
  final String? sub;
  final String value;
  final Color? valueColor;
  final bool headline;
  final bool nested;
  const _StmtRow({
    required this.label,
    this.sub,
    required this.value,
    this.valueColor,
    this.headline = false,
    this.nested = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = headline
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.titleSmall?.copyWith(
            fontWeight: nested ? FontWeight.w500 : FontWeight.w600,
          );
    final valueStyle =
        (headline
                ? theme.textTheme.headlineMedium
                : theme.textTheme.titleMedium)
            ?.copyWith(
              color: valueColor ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
    return Padding(
      padding: EdgeInsets.only(
        left: nested ? 16 : 0,
        top: nested ? 3 : 0,
        bottom: nested ? 3 : 0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: labelStyle),
                if (sub != null)
                  Text(
                    sub!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: valueStyle),
        ],
      ),
    );
  }
}

// "Show your work" grid: the raw Price/Shares/NAV/Cost-basis/Unrealized-G/L the
// statement above is computed from, across the start (~1y ago) and current month.
class _ReferenceGrid extends StatelessWidget {
  final YieldResult result;
  const _ReferenceGrid({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    final bars = r.priceBars;
    final startLabel = bars.isNotEmpty ? _monthLabel(bars.first.date) : 'Start';
    final endLabel = bars.isNotEmpty ? _monthLabel(bars.last.date) : 'Now';

    final headStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = theme.textTheme.bodyMedium;
    final numStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    TableRow row(String label, String start, String end, {Color? endColor}) {
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(label, style: labelStyle),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
            child: Text(start, textAlign: TextAlign.right, style: numStyle),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(
              end,
              textAlign: TextAlign.right,
              style: numStyle?.copyWith(color: endColor),
            ),
          ),
        ],
      );
    }

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: IntrinsicColumnWidth(),
        2: IntrinsicColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                startLabel,
                textAlign: TextAlign.right,
                style: headStyle,
              ),
            ),
            Text(endLabel, textAlign: TextAlign.right, style: headStyle),
          ],
        ),
        row('Price', _money(r.startPrice), _money(r.currentPrice)),
        row('Shares', '1.00', r.dripShares.toStringAsFixed(2)),
        row(
          'Present Value (price × shares)',
          _money(r.startPrice),
          _money(r.nav),
        ),
        row('Cost basis', _money(r.startPrice), _money(r.costBasis)),
        row(
          'Unrealized G/L',
          '—',
          _signedMoney(r.unrealizedGL),
          endColor: _signColor(r.unrealizedGL),
        ),
      ],
    );
  }
}

// "Show your work" for a multi-lot portfolio: one row per lot (buy date, shares
// bought → now, cost, value, G/L) plus a totals row. Replaces the single-share
// reference grid when the user enters real lots.
class _PortfolioGrid extends StatelessWidget {
  final YieldResult result;
  const _PortfolioGrid({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    final headStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final numStyle = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget cell(String t, {Color? color, bool head = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Text(
        t,
        textAlign: TextAlign.right,
        style: head ? headStyle : numStyle?.copyWith(color: color),
      ),
    );

    final totalInitial = r.lots.fold<double>(0, (s, l) => s + l.initialShares);
    final totalFinal = r.lots.fold<double>(0, (s, l) => s + l.finalShares);

    // Closed lots show "buy→sell" months; open lots just the buy month.
    TableRow lotRow(LotResult l) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Text(
            l.isClosed
                ? '${_monthLabel(l.buyDate)}→${_monthLabel(l.sellDate!)}'
                : _monthLabel(l.buyDate),
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: l.isClosed ? FontStyle.italic : null,
            ),
          ),
        ),
        cell(
          '${l.initialShares.toStringAsFixed(2)}→${l.finalShares.toStringAsFixed(2)}',
        ),
        cell(_money(l.cost)),
        cell(_money(l.nav)),
        cell(_signedMoney(l.gl), color: _signColor(l.gl)),
      ],
    );

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.4),
        1: IntrinsicColumnWidth(),
        2: IntrinsicColumnWidth(),
        3: IntrinsicColumnWidth(),
        4: IntrinsicColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            cell('Lot', head: true),
            cell('Shares', head: true),
            cell('Cost', head: true),
            cell('Value', head: true),
            cell('G/L', head: true),
          ],
        ),
        for (final l in r.lots) lotRow(l),
        TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text(
                'Total',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            cell(
              '${totalInitial.toStringAsFixed(2)}→${totalFinal.toStringAsFixed(2)}',
            ),
            cell(_money(r.totalCost)),
            cell(_money(r.nav)),
            cell(
              _signedMoney(r.unrealizedGL + r.realizedGL),
              color: _signColor(r.unrealizedGL + r.realizedGL),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Shared formatting helpers (top-level so every widget reuses one copy) ───
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

final Color _gain = Colors.greenAccent.shade400;
final Color _loss = Colors.redAccent.shade200;
Color _signColor(double v) => v < 0 ? _loss : _gain;

String _money(double v) => '\$${v.toStringAsFixed(2)}';
String _signedMoney(double v) =>
    '${v < 0 ? '−' : '+'}\$${v.abs().toStringAsFixed(2)}';
String _signedPct(double v) =>
    '${v < 0 ? '−' : '+'}${(v.abs() * 100).toStringAsFixed(1)}%';
String _pctPlain(double v) => '${(v * 100).toStringAsFixed(1)}%';

// "Jan '25" — compact month label for the reference grid columns.
String _monthLabel(DateTime d) =>
    "${_months[d.month - 1]} '${(d.year % 100).toString().padLeft(2, '0')}";

// "Dec 31, 2025" — readable date for the distribution/price lists.
String fmtDateHuman(DateTime d) =>
    '${_months[d.month - 1]} ${d.day}, ${d.year}';

// "Jan 2025" — readable month range endpoints.
String _fmtMonthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

// "May 28, 2026, 8:41 PM" — when a result was fetched (no intl dependency).
String fmtStamp(DateTime d) {
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${fmtDateHuman(d)}, $h12:$mm $ampm';
}

// True when fetchedAt and now fall on different calendar dates — i.e. the shown
// result was computed on an earlier day and its TTM window has since shifted.
bool isStale(DateTime fetchedAt, DateTime now) =>
    fetchedAt.year != now.year ||
    fetchedAt.month != now.month ||
    fetchedAt.day != now.day;

class _DistributionsTab extends StatelessWidget {
  final YieldResult? result;
  // Per-distribution ROC editing. [rocOverrides] are keyed by div epoch
  // (seconds); a row with no override shows [defaultRoc]. [onRocChanged] sets
  // (or clears, with null) an override and recomputes the result in place.
  final Map<int, double> rocOverrides;
  final double defaultRoc;
  final void Function(int epoch, double? pct) onRocChanged;
  const _DistributionsTab({
    required this.result,
    this.rocOverrides = const {},
    this.defaultRoc = 0,
    this.onRocChanged = _noop,
  });

  static void _noop(int epoch, double? pct) {}

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Run Calculate to populate.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (r.distributions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${r.ticker}: no distributions in the last 12 months.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final total = r.sumDistributions;
    final theme = Theme.of(context);
    final firstDate = r.distributions.last.date;
    final lastDate = r.distributions.first.date;
    final avg = total / r.distributions.length;
    // Per-share figures — the ROC split is a per-share concept independent of
    // the lots. With per-distribution ROC the effective rate is a blend.
    final taxableIncome = r.perShareIncome;
    final rocAmount = total - taxableIncome;
    final taxThisYear = r.perShareIncome * r.combinedRate;
    final rocInt = total > 0 ? (rocAmount / total * 100).round() : 0;
    final incInt = 100 - rocInt;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: r.distributions.length + 3,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${r.distributions.length} payouts · '
                  '${_fmtMonthYear(firstDate)} – ${_fmtMonthYear(lastDate)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                _StmtRow(label: 'Total distributions', value: _money(total)),
                _StmtRow(label: 'Average per payout', value: _money(avg)),
                _StmtRow(
                  label: 'Return of capital ($rocInt%)',
                  value: _money(rocAmount),
                  nested: true,
                ),
                _StmtRow(
                  label: 'Taxable income ($incInt%)',
                  value: _money(taxableIncome),
                  nested: true,
                ),
                _StmtRow(
                  label: 'Tax this year',
                  value: _signedMoney(-taxThisYear),
                  valueColor: _loss,
                  nested: true,
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap a row’s ROC % to override it (e.g. from a YieldMax '
                  '19a-1 notice). Blank = the $rocInt% default above.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          final headStyle = theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(flex: 4, child: Text('Date', style: headStyle)),
                Expanded(
                  flex: 3,
                  child: Text(
                    'Amount',
                    textAlign: TextAlign.right,
                    style: headStyle,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'ROC %',
                    textAlign: TextAlign.right,
                    style: headStyle,
                  ),
                ),
              ],
            ),
          );
        }
        if (i == r.distributions.length + 2) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total (12mo)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '\$${total.toStringAsFixed(4)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }
        final d = r.distributions[i - 2];
        final epoch = d.date.toUtc().millisecondsSinceEpoch ~/ 1000;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 4, child: Text(fmtDateHuman(d.date))),
              Expanded(
                flex: 3,
                child: Text(
                  '\$${d.amount.toStringAsFixed(4)}',
                  textAlign: TextAlign.right,
                ),
              ),
              Expanded(
                flex: 3,
                child: _RocCell(
                  overrideRoc: rocOverrides[epoch],
                  defaultRoc: defaultRoc,
                  onChanged: (pct) => onRocChanged(epoch, pct),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// One editable ROC-% cell for a distribution row. Shows the override if set,
// otherwise the default as a hint. Commits on submit/focus-loss; an empty value
// clears the override (reverts to the default).
class _RocCell extends StatefulWidget {
  final double? overrideRoc;
  final double defaultRoc;
  final ValueChanged<double?> onChanged;
  const _RocCell({
    required this.overrideRoc,
    required this.defaultRoc,
    required this.onChanged,
  });

  @override
  State<_RocCell> createState() => _RocCellState();
}

class _RocCellState extends State<_RocCell> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.overrideRoc == null ? '' : _fmt(widget.overrideRoc!),
    );
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) {
      widget.onChanged(null);
      return;
    }
    final v = double.tryParse(t);
    if (v != null && v >= 0 && v <= 100) widget.onChanged(v);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: _fmt(widget.defaultRoc),
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        border: const OutlineInputBorder(),
        suffixText: '%',
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onSubmitted: (_) => _commit(),
    );
  }
}

class _PricesTab extends StatelessWidget {
  final YieldResult? result;
  const _PricesTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Run Calculate to populate.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final closes = [...r.priceBars]..sort((a, b) => b.date.compareTo(a.date));
    if (closes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No daily closes returned.', textAlign: TextAlign.center),
        ),
      );
    }
    final theme = Theme.of(context);
    final valid = closes.map((c) => c.close).whereType<double>().toList();
    final mean = valid.isEmpty
        ? 0.0
        : valid.reduce((a, b) => a + b) / valid.length;
    final hi = valid.isEmpty ? 0.0 : valid.reduce((a, b) => a > b ? a : b);
    final lo = valid.isEmpty ? 0.0 : valid.reduce((a, b) => a < b ? a : b);
    final last = closes.first.date;
    final first = closes.last.date;
    final pctChange = (valid.length >= 2)
        ? (valid.first - valid.last) / valid.last * 100
        : 0.0;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: closes.length + 2,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${closes.length} daily closes · '
                  '${_fmtMonthYear(first)} – ${_fmtMonthYear(last)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                _StmtRow(label: 'Current price', value: _money(r.currentPrice)),
                _StmtRow(
                  label: '12-month change',
                  value: _signedPct(pctChange / 100),
                  valueColor: _signColor(pctChange),
                ),
                _StmtRow(
                  label: 'Average close',
                  value: _money(mean),
                  nested: true,
                ),
                _StmtRow(
                  label: 'Range',
                  value: '${_money(lo)} – ${_money(hi)}',
                  nested: true,
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Date',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Closing price',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }
        final c = closes[i - 2];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(fmtDateHuman(c.date)),
              Text(c.close == null ? '—' : '\$${c.close!.toStringAsFixed(2)}'),
            ],
          ),
        );
      },
    );
  }
}
