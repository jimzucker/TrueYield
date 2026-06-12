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

/// One purchase: [shares] (qty) of the ticker bought on [buyDate] at [price] per
/// share. Principal (cost) = shares × price and is derived, not stored, so it
/// recomputes whenever qty or price changes. [price] is null until set; the buy-
/// date market close is used as the default. If [sellDate] is null the lot is
/// still held (unrealized); otherwise it was sold on that date and books a
/// realized gain. The synthesized default lot — 1 share at the window start,
/// still held — reproduces the app's original "one share a year ago" behavior.
class Lot {
  final DateTime buyDate;
  final double? shares; // quantity
  final double? price; // per-share basis; null → use the buy-date market close
  final DateTime? sellDate; // null = still held

  const Lot({required this.buyDate, this.shares, this.price, this.sellDate});

  bool get isClosed => sellDate != null;

  /// Initial share count (the entered quantity).
  double initialShares(double marketPrice) => shares ?? 0;

  /// Per-share basis: the entered price, else the buy-date [marketPrice].
  double pricePerShare(double marketPrice) => price ?? marketPrice;

  /// Principal invested = shares × price (price falls back to [marketPrice]).
  double initialCost(double marketPrice) =>
      (shares ?? 0) * (price ?? marketPrice);

  Map<String, dynamic> toJson() => {
    'buyDate': buyDate.toUtc().millisecondsSinceEpoch,
    if (shares != null) 'shares': shares,
    if (price != null) 'price': price,
    if (sellDate != null) 'sellDate': sellDate!.toUtc().millisecondsSinceEpoch,
  };

  factory Lot.fromJson(Map<String, dynamic> j) {
    double? shares = (j['shares'] as num?)?.toDouble();
    double? price = (j['price'] as num?)?.toDouble();
    // Migrate older shapes: {shares, cost} → price = cost ÷ shares; the original
    // {mode, amount} where mode==shares → shares=amount (price unknown).
    if (price == null) {
      final cost = (j['cost'] as num?)?.toDouble();
      if (cost != null && shares != null && shares > 0) {
        price = cost / shares;
      } else if (shares == null &&
          j['amount'] != null &&
          j['mode'] != 'dollars') {
        shares = (j['amount'] as num).toDouble();
      }
    }
    return Lot(
      buyDate: DateTime.fromMillisecondsSinceEpoch(
        (j['buyDate'] as num).toInt(),
        isUtc: true,
      ),
      shares: shares,
      price: price,
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

  /// Holding period in whole days for a closed lot; null while still held.
  int? get holdingDays => sellDate?.difference(buyDate).inDays;

  /// Long-term capital gain if held more than a year (open lots aren't
  /// realized, so this is false for them).
  bool get isLongTerm => (holdingDays ?? 0) > 365;

  // Total return on this lot's cost, before and after this year's income tax.
  double get totalReturnBeforeTax => cost > 0 ? (nav - cost) / cost : 0.0;
  double get totalReturnAfterTax =>
      cost > 0 ? (nav - taxThisYear - cost) / cost : 0.0;
  // DRIP share growth on this lot (finalShares ÷ initialShares − 1).
  double get sharesGrowth =>
      initialShares > 0 ? finalShares / initialShares - 1 : 0.0;

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
  // Income tax owed this year, on the income (non-ROC) portion only.
  final double taxThisYear;
  // Capital-gains tax on closed lots' realized gains. Short-term gains (held
  // ≤ 1y) are taxed at the ordinary [combinedRate]; long-term at [ltRate]
  // (= LT-federal + state + local). Realized losses net within and across the
  // ST/LT buckets before tax. Always 0 when nothing is sold (and in the
  // default no-lots view), so the per-share TTM statement is unaffected.
  final double capGainsTax;
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

  // Portfolio share totals across all lots (the widgets used to fold these).
  double get totalInitialShares =>
      lots.fold(0.0, (s, l) => s + l.initialShares);
  double get totalFinalShares => lots.fold(0.0, (s, l) => s + l.finalShares);

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
    required this.capGainsTax,
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
      capGainsTax: 0,
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

/// One self-test scenario for the Diagnostics tab: a labeled [YieldResult]
/// computed from synthetic data, plus a list of [checks] that compare the
/// computed numbers against expected values baked in from the (deliberately
/// round) synthetic inputs. A scenario [pass]es when every check matches.
class DiagnosticScenario {
  final String label;
  final String detail;
  final YieldResult result;
  final List<DiagCheck> checks;
  const DiagnosticScenario(
    this.label,
    this.detail,
    this.result, {
    this.checks = const [],
  });

  bool get pass => checks.every((c) => c.ok);
}

/// A single expected-vs-actual assertion shown on a Diagnostics card and
/// asserted by the test suite. [expected] is derived from the synthetic inputs
/// (see buildDiagnostics); [actual] is what the lot math produced.
class DiagCheck {
  final String label;
  final double expected;
  final double actual;
  const DiagCheck(this.label, this.expected, this.actual);

  // Relative + small absolute tolerance so pinned round values don't trip on
  // floating-point dust or sub-cent DRIP rounding.
  bool get ok => (expected - actual).abs() <= expected.abs() * 1e-3 + 0.01;
}
