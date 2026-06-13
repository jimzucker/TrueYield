import 'package:flutter_test/flutter_test.dart';
import 'package:true_yield/main.dart';

const _eps = 1e-9;

DateTime _utc(int y, [int m = 1, int d = 1]) => DateTime.utc(y, m, d);

void main() {
  group('returnBarParts — cost→value stacked bar data prep', () {
    test('the parts reconcile: nav = cost+income+gain, net = nav−tax', () {
      final r = YieldMath.compute(
        ticker: 'BAR',
        currentPrice: 120,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 9, 15), amount: 5)],
        priceBars: [
          PriceBar(date: _utc(2025, 6), close: 100),
          PriceBar(date: _utc(2026, 6), close: 120),
        ],
        lots: [Lot(buyDate: _utc(2025, 6, 1), shares: 10, price: 100)],
      );
      final p = returnBarParts(r);
      expect(p.cost, closeTo(r.totalCost, _eps));
      expect(p.income, closeTo(r.incomeAmount, _eps));
      expect(p.gain, closeTo(r.unrealizedGL + r.realizedGL, _eps));
      expect(p.tax, closeTo(r.taxThisYear + r.capGainsTax, _eps));
      // The stack sums to NAV, and the after-tax value is NAV minus tax.
      expect(p.nav, closeTo(p.cost + p.income + p.gain, _eps));
      expect(p.nav, closeTo(r.nav, _eps));
      expect(p.netValue, closeTo(r.nav - p.tax, _eps));
    });

    test('a sold long-term lot folds realized gain and gains tax in', () {
      final r = YieldMath.compute(
        ticker: 'BAR',
        currentPrice: 120,
        federalPct: 30,
        statePct: 5,
        localPct: 0,
        ltGainsPct: 15,
        distributions: [DistributionEntry(date: _utc(2023, 12), amount: 1)],
        priceBars: [
          PriceBar(date: _utc(2024, 1), close: 100),
          PriceBar(date: _utc(2025, 6), close: 130),
        ],
        lots: [
          Lot(
            buyDate: _utc(2024, 1, 1),
            shares: 10,
            price: 80,
            sellDate: _utc(2025, 6, 1),
          ),
        ],
      );
      final p = returnBarParts(r);
      expect(p.gain, closeTo(r.realizedGL, _eps)); // all realized, nothing held
      expect(p.tax, greaterThan(0)); // capital-gains tax is in the bite
      expect(p.netValue, closeTo(p.nav - p.tax, _eps));
    });

    test('a price loss makes the gain part negative', () {
      final r = YieldMath.compute(
        ticker: 'BAR',
        currentPrice: 70,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 9, 15), amount: 5)],
        priceBars: [
          PriceBar(date: _utc(2025, 6), close: 100),
          PriceBar(date: _utc(2026, 6), close: 70),
        ],
        lots: [Lot(buyDate: _utc(2025, 6, 1), shares: 10, price: 100)],
      );
      final p = returnBarParts(r);
      expect(p.gain, lessThan(0));
      expect(p.nav, closeTo(p.cost + p.income + p.gain, _eps));
    });
  });
}
