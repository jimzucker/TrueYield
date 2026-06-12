import 'package:flutter_test/flutter_test.dart';
import 'package:true_yield/main.dart';

const _eps = 1e-9;

DateTime _utc(int y, [int m = 1, int d = 1]) => DateTime.utc(y, m, d);

void main() {
  group('waterfallSteps — total-return waterfall data prep', () {
    // A simple open-lot result (no sale): combined 37%, ROC 0.
    YieldResult openResult() => YieldMath.compute(
      ticker: 'WF',
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

    test('the steps start at cost, end at the after-tax value', () {
      final r = openResult();
      final steps = waterfallSteps(r, defaultView: false);
      expect(steps.first.label, 'Cost');
      expect(steps.first.isTotal, isTrue);
      expect(steps.first.delta, closeTo(r.totalCost, _eps));
      expect(steps.last.label, 'Value');
      expect(steps.last.isTotal, isTrue);
      expect(
        steps.last.delta,
        closeTo(r.nav - r.taxThisYear - r.capGainsTax, _eps),
      );
    });

    test('the start level plus the signed deltas equals the end value', () {
      final r = openResult();
      final steps = waterfallSteps(r, defaultView: false);
      final start = steps.first.delta;
      final deltaSum = steps
          .where((s) => !s.isTotal)
          .fold<double>(0, (a, s) => a + s.delta);
      expect(start + deltaSum, closeTo(steps.last.delta, 1e-6));
    });

    test('an open / no-sale result has no Real G/L or CG tax steps', () {
      final r = openResult();
      final labels = waterfallSteps(
        r,
        defaultView: false,
      ).map((s) => s.label).toList();
      expect(labels.contains('Real G/L'), isFalse);
      expect(labels.contains('CG tax'), isFalse);
      expect(
        labels,
        containsAllInOrder(['Cost', 'Income', 'Inc tax', 'Value']),
      );
    });

    test('a closed long-term lot adds Real G/L and CG tax steps', () {
      final r = YieldMath.compute(
        ticker: 'WF',
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
      expect(r.capGainsTax, greaterThan(0));
      final labels = waterfallSteps(
        r,
        defaultView: false,
      ).map((s) => s.label).toList();
      expect(labels.contains('Real G/L'), isTrue);
      expect(labels.contains('CG tax'), isTrue);
      // Still balances: cost + deltas = after-tax value.
      final steps = waterfallSteps(r, defaultView: false);
      final deltaSum = steps
          .where((s) => !s.isTotal)
          .fold<double>(0, (a, s) => a + s.delta);
      expect(steps.first.delta + deltaSum, closeTo(steps.last.delta, 1e-6));
    });

    test('the default (no-lots) view labels the start "Start"', () {
      final r = YieldMath.compute(
        ticker: 'WF',
        currentPrice: 120,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 9, 15), amount: 5)],
        priceBars: [
          PriceBar(date: _utc(2025, 6), close: 100),
          PriceBar(date: _utc(2026, 6), close: 120),
        ],
      );
      final steps = waterfallSteps(r, defaultView: true);
      expect(steps.first.label, 'Start');
    });
  });
}
