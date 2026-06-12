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

part of 'main.dart';

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
    // Long-term capital-gains rate, federal only; the effective LT rate adds
    // State + Local (most states tax LT gains as ordinary income). Short-term
    // gains use the ordinary combined rate. Default 15 (the common LT bracket).
    double ltGainsPct = 15,
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
    // Effective long-term rate: LT-federal + the same state/local as ordinary.
    final ltRate = ((ltGainsPct + statePct + localPct) / 100.0).clamp(0.0, 1.0);
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
        realizedGL = 0,
        realizedST = 0,
        realizedLT = 0;
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
        if (l.isLongTerm) {
          realizedLT += l.gl;
        } else {
          realizedST += l.gl;
        }
      } else {
        unrealizedGL += l.gl;
      }
    }
    // Capital-gains tax: net each bucket, let a losing bucket offset the other,
    // then tax the remaining positive ST at the ordinary rate and LT at ltRate.
    double netST = realizedST, netLT = realizedLT;
    if (netST < 0) {
      netLT += netST;
      netST = 0;
    } else if (netLT < 0) {
      netST += netLT;
      netLT = 0;
    }
    final capGainsTax =
        (netST > 0 ? netST * combined : 0.0) +
        (netLT > 0 ? netLT * ltRate : 0.0);
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
        ? (nav - taxThisYear - capGainsTax - totalCost) / totalCost
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
      capGainsTax: capGainsTax,
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

/// Deterministic self-test scenarios computed from synthetic data anchored to
/// [now] (no network). The inputs are deliberately round so the expected
/// numbers are checkable by hand: prices step $10 → $15 → $20 across three
/// one-year bands (and a mirror $20 → $15 → $10 path for the falling case), a
/// flat $0.10 monthly distribution, 30% tax (all federal), and 50% ROC. Because
/// every price is keyed to whole months-ago, the results are independent of the
/// absolute date — so the expected values pinned in [checks] are stable. Covers
/// no lots, holds under/over a year and over two years, several lots, a closed
/// lot, and a position whose price fell. The Diagnostics tab and the tests share
/// this one source of truth. Pure (takes [now]).
List<DiagnosticScenario> buildDiagnostics(DateTime now) {
  final today = DateTime.utc(now.year, now.month, now.day);
  const months = 37; // ~3 years of monthly bars

  // Round prices keyed to a bar's age in months: oldest year $10, middle $15,
  // newest $20. The falling path is the mirror image.
  double rising(int monthsAgo) =>
      monthsAgo >= 24 ? 10 : (monthsAgo >= 12 ? 15 : 20);
  double falling(int monthsAgo) =>
      monthsAgo >= 24 ? 20 : (monthsAgo >= 12 ? 15 : 10);

  List<PriceBar> barsFor(double Function(int) priceAt) => [
    for (int i = months - 1; i >= 0; i--)
      PriceBar(
        date: DateTime.utc(today.year, today.month - i, 1),
        close: priceAt(i),
      ),
  ];

  // A flat $0.10 every month — frequent enough that even a 3-month lot catches
  // a few, small enough that DRIP share growth stays easy to follow.
  final dists = <DistributionEntry>[
    for (int i = months - 1; i >= 1; i--)
      DistributionEntry(
        date: DateTime.utc(today.year, today.month - i, 15),
        amount: 0.10,
      ),
  ];

  final barsUp = barsFor(rising);
  final barsDown = barsFor(falling);
  DateTime ago(int m) => DateTime.utc(today.year, today.month - m, today.day);

  YieldResult run(List<Lot>? lots, {List<PriceBar>? bars}) => YieldMath.compute(
    ticker: 'DIAG',
    currentPrice: (bars ?? barsUp).last.close!,
    federalPct: 30,
    statePct: 0,
    localPct: 0,
    distributions: dists,
    priceBars: bars ?? barsUp,
    rocPct: 50,
    lots: lots,
  );

  // Build a scenario and attach the standard expected-vs-actual checks. The
  // expected values are passed in (pinned from the round inputs); [costExp],
  // [valueExp], [sharesExp], [returnPctExp] map to the headline result fields.
  DiagnosticScenario scn(
    String label,
    String detail,
    YieldResult r, {
    required double costExp,
    required double valueExp,
    required double sharesExp,
    required double returnPctExp,
  }) => DiagnosticScenario(
    label,
    detail,
    r,
    checks: [
      DiagCheck('Cost', costExp, r.totalCost),
      DiagCheck('Value', valueExp, r.nav),
      DiagCheck('Shares', sharesExp, r.dripShares),
      DiagCheck(
        'After-tax return %',
        returnPctExp,
        r.totalReturnAfterTax * 100,
      ),
    ],
  );

  final baseline = run(null); // the canonical "1 share, full window" result
  return [
    scn(
      'No lots',
      '1 share held the full ~3y window · all distributions reinvested',
      baseline,
      costExp: 10, // 1 share × $10 start
      valueExp: 26.04, // 1.3021 DRIP shares × $20 now
      sharesExp: 1.30,
      returnPctExp: 155.01,
    ),
    // Invariant: a single 1-share lot bought at the window start must reproduce
    // the "No lots" default exactly (checked against baseline, not pinned).
    scn(
      '1 lot ≡ default',
      'one 1-share lot at the window start must equal "No lots"',
      run([
        Lot(
          buyDate: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          shares: 1,
        ),
      ]),
      costExp: baseline.totalCost,
      valueExp: baseline.nav,
      sharesExp: baseline.dripShares,
      returnPctExp: baseline.totalReturnAfterTax * 100,
    ),
    scn(
      '1 lot · 3 months',
      'held under 12 months · 100 sh',
      run([Lot(buyDate: ago(3), shares: 100)]),
      costExp: 2000, // 100 sh × $20
      valueExp: 2030.15,
      sharesExp: 101.51,
      returnPctExp: 1.28,
    ),
    scn(
      '1 lot · 18 months',
      'held over 12 months · 100 sh',
      run([Lot(buyDate: ago(18), shares: 100)]),
      costExp: 1500, // 100 sh × $15
      valueExp: 2213.38,
      sharesExp: 110.67,
      returnPctExp: 45.76,
    ),
    scn(
      '1 lot · 30 months',
      'held over 2 years · 100 sh',
      run([Lot(buyDate: ago(30), shares: 100)]),
      costExp: 1000, // 100 sh × $10
      valueExp: 2453.21,
      sharesExp: 122.66,
      returnPctExp: 140.82,
    ),
    scn(
      'Multiple lots',
      '3 lots bought 3 / 18 / 30 months ago',
      run([
        Lot(buyDate: ago(3), shares: 100),
        Lot(buyDate: ago(18), shares: 100),
        Lot(buyDate: ago(30), shares: 100),
      ]),
      costExp: 4500, // 2000 + 1500 + 1000
      valueExp: 6696.74,
      sharesExp: 334.84,
      returnPctExp: 47.12,
    ),
    scn(
      'Closed lot (long-term)',
      'bought 30 mo ago at \$10, sold 6 mo ago at \$20 · long-term gain',
      run([Lot(buyDate: ago(30), shares: 100, sellDate: ago(6))]),
      costExp: 1000, // 100 sh × $10
      valueExp: 2380.88, // 119.04 DRIP shares locked at the $20 sale
      sharesExp: 119.04,
      returnPctExp: 115.58, // after 15%+0% long-term gains tax on the gain
    ),
    scn(
      'Falling price',
      'bought 18 mo ago at \$15, now \$10 · 100 sh',
      run([Lot(buyDate: ago(18), shares: 100)], bars: barsDown),
      costExp: 1500, // 100 sh × $15
      valueExp: 1168.79, // 116.88 DRIP shares × $10 now → a loss
      sharesExp: 116.88,
      returnPctExp: -23.88,
    ),
  ];
}
