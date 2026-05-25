// Copyright 2026 Jim Zucker
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

import 'package:flutter_test/flutter_test.dart';
import 'package:iyield/main.dart';

/// Closeness tolerance for yield comparisons. 1e-9 is tight enough to catch
/// any real math error and loose enough to survive harmless IEEE-754 drift.
const _eps = 1e-9;

DateTime _utc(int y, int m, [int d = 1]) => DateTime.utc(y, m, d);

void main() {
  group('YieldMath.compute — qualifying paths', () {
    test('simple two-distribution case at flat price, zero tax', () {
      // Flat $100 price, two $1 distributions → simple TTM 2%, DRIP slightly
      // higher because each $1 buys 0.01 share at $100 and the second
      // distribution compounds on top.
      final result = YieldMath.compute(
        ticker: 'FLAT',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 7, 15), amount: 1.00),
          DistributionEntry(date: _utc(2026, 1, 15), amount: 1.00),
        ],
        monthlyCloses: [
          for (int m = 0; m < 13; m++)
            MonthlyClose(monthStart: _utc(2025, 6 + m), close: 100),
        ],
      );

      expect(result.qualifies, isTrue);
      expect(result.sumDistributions, closeTo(2.00, _eps));
      expect(result.grossYield, closeTo(0.02, _eps));
      expect(result.afterTaxYield, closeTo(0.02, _eps));
      expect(result.compoundedGrossYield,
          closeTo((1 + 0.01) * (1 + 0.01) - 1, _eps));
      expect(result.compoundedGrossYield,
          greaterThan(result.grossYield));
      expect(result.avgPriceGrossYield, closeTo(0.02, _eps));
      // TWR at flat price with $2 of distributions ≈ 2.0001%
      // (only the dist-bearing months contribute; sum > simple because
      // distributions compound across two non-adjacent months).
      expect(result.twrGross, greaterThan(0));
    });

    test('after-tax yield is gross × (1 − combined rate)', () {
      final result = YieldMath.compute(
        ticker: 'TAX',
        currentPrice: 100,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 7, 15), amount: 10),
        ],
        monthlyCloses: [
          for (int m = 0; m < 13; m++)
            MonthlyClose(monthStart: _utc(2025, 6 + m), close: 100),
        ],
      );
      expect(result.grossYield, closeTo(0.10, _eps));
      expect(result.afterTaxYield, closeTo(0.10 * 0.63, _eps));
      expect(result.avgPriceAfterTaxYield, closeTo(0.10 * 0.63, _eps));
      // DRIP after-tax shaves the distribution by the same factor.
      expect(result.compoundedAfterTaxYield,
          closeTo(result.compoundedGrossYield * 0.63, _eps));
    });

    test('price drop → DRIP < simple, TWR negative when payouts < price loss',
        () {
      // Price drops from 100 → 80, single $5 distribution at mid-period.
      // Simple TTM: 5 / 80 = 6.25%
      // DRIP at mid-price (say 90): (1 + 5/90) - 1 ≈ 5.56% < simple
      // TWR roughly (80 + 5) / 100 - 1 = -15%
      final result = YieldMath.compute(
        ticker: 'DROP',
        currentPrice: 80,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 15), amount: 5),
        ],
        monthlyCloses: [
          MonthlyClose(monthStart: _utc(2025, 6), close: 100),
          MonthlyClose(monthStart: _utc(2025, 12), close: 90),
          MonthlyClose(monthStart: _utc(2026, 6), close: 80),
        ],
      );
      expect(result.grossYield, closeTo(5 / 80, _eps));
      expect(result.compoundedGrossYield, lessThan(result.grossYield));
      expect(result.compoundedGrossYield, closeTo(5 / 90, _eps));
      expect(result.twrGross, lessThan(0));
    });

    test('price rise → DRIP > simple', () {
      // Price rises from 80 → 100, single $5 distribution at mid-period.
      // Simple TTM: 5 / 100 = 5%
      // DRIP at mid-price (90): 5 / 90 ≈ 5.56% > simple
      final result = YieldMath.compute(
        ticker: 'RISE',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 15), amount: 5),
        ],
        monthlyCloses: [
          MonthlyClose(monthStart: _utc(2025, 6), close: 80),
          MonthlyClose(monthStart: _utc(2025, 12), close: 90),
          MonthlyClose(monthStart: _utc(2026, 6), close: 100),
        ],
      );
      expect(result.compoundedGrossYield, greaterThan(result.grossYield));
      expect(result.compoundedGrossYield, closeTo(5 / 90, _eps));
      // Total return: 100/80 - 1 = 25% plus distribution -> positive.
      expect(result.twrGross, greaterThan(0));
    });

    test('average-price denominator equals sum / mean(closes)', () {
      // Closes: 100, 120, 80 → mean = 100.
      final result = YieldMath.compute(
        ticker: 'AVG',
        currentPrice: 80,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 15), amount: 6),
        ],
        monthlyCloses: [
          MonthlyClose(monthStart: _utc(2025, 6), close: 100),
          MonthlyClose(monthStart: _utc(2025, 12), close: 120),
          MonthlyClose(monthStart: _utc(2026, 6), close: 80),
        ],
      );
      expect(result.avgPriceGrossYield, closeTo(6 / 100, _eps));
    });

    test('distributions list returned newest first', () {
      final result = YieldMath.compute(
        ticker: 'ORDER',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 7, 15), amount: 1),
          DistributionEntry(date: _utc(2026, 1, 15), amount: 1),
          DistributionEntry(date: _utc(2025, 10, 15), amount: 1),
        ],
        monthlyCloses: [
          for (int m = 0; m < 13; m++)
            MonthlyClose(monthStart: _utc(2025, 6 + m), close: 100),
        ],
      );
      expect(result.distributions.first.date, _utc(2026, 1, 15));
      expect(result.distributions.last.date, _utc(2025, 7, 15));
    });

    test('YMAG-like fixture matches pre-computed expected values', () {
      // Real YMAG response captured 2026-05-25:
      //  - current price $12.79
      //  - 13 distributions summing to $2.0050
      //  - 13 monthly closes ranging $11.95 → $15.71
      // Combined rate 37% (federal 32, state 5, local 0).
      //
      // Expected values were re-derived from the same input by an independent
      // Python reference implementation, so they assert the algorithm's
      // numerical output rather than a number we hand-edited.
      final result = YieldMath.compute(
        ticker: 'YMAG',
        currentPrice: 12.79,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [
          DistributionEntry(amount: 0.2930, date: _ymagTs(2025, 5, 29)),
          DistributionEntry(amount: 0.2090, date: _ymagTs(2025, 6, 5)),
          DistributionEntry(amount: 0.1710, date: _ymagTs(2025, 6, 12)),
          DistributionEntry(amount: 0.1690, date: _ymagTs(2025, 6, 20)),
          DistributionEntry(amount: 0.1570, date: _ymagTs(2025, 6, 26)),
          DistributionEntry(amount: 0.0550, date: _ymagTs(2025, 7, 3)),
          DistributionEntry(amount: 0.1260, date: _ymagTs(2025, 7, 10)),
          DistributionEntry(amount: 0.1520, date: _ymagTs(2025, 7, 17)),
          DistributionEntry(amount: 0.2030, date: _ymagTs(2025, 7, 24)),
          DistributionEntry(amount: 0.0750, date: _ymagTs(2025, 7, 31)),
          DistributionEntry(amount: 0.0800, date: _ymagTs(2025, 8, 7)),
          DistributionEntry(amount: 0.1620, date: _ymagTs(2025, 8, 14)),
          DistributionEntry(amount: 0.1530, date: _ymagTs(2026, 5, 20)),
        ],
        monthlyCloses: _ymagMonthlyCloses,
      );
      expect(result.qualifies, isTrue);
      expect(result.sumDistributions, closeTo(2.0050, 1e-6));
      expect(result.grossYield, closeTo(0.156763, 1e-5));
      expect(result.afterTaxYield, closeTo(0.098761, 1e-5));
      expect(result.compoundedGrossYield, closeTo(0.141274, 1e-5));
      expect(result.compoundedAfterTaxYield, closeTo(0.087011, 1e-5));
      expect(result.avgPriceGrossYield, closeTo(0.142439, 1e-5));
      expect(result.avgPriceAfterTaxYield, closeTo(0.089737, 1e-5));
      expect(result.twrGross, closeTo(-0.062668, 1e-5));
      expect(result.twrAfterTax, closeTo(-0.100041, 1e-5));
    });
  });

  group('YieldMath.compute — non-qualifying / edge cases', () {
    test('no distributions → does not qualify, prices preserved', () {
      final closes = [
        MonthlyClose(monthStart: _utc(2025, 6), close: 100),
        MonthlyClose(monthStart: _utc(2026, 5), close: 110),
      ];
      final result = YieldMath.compute(
        ticker: 'BRK-B',
        currentPrice: 486.38,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: const [],
        monthlyCloses: closes,
      );
      expect(result.qualifies, isFalse);
      expect(result.reason,
          equals('no distributions in last 12 months'));
      expect(result.grossYield, 0);
      expect(result.afterTaxYield, 0);
      expect(result.compoundedGrossYield, 0);
      expect(result.twrGross, 0);
      // Prices are still surfaced for the Prices tab.
      expect(result.monthlyCloses.length, closes.length);
      expect(result.distributions, isEmpty);
    });

    test('all monthly closes null → falls back to currentPrice for DRIP', () {
      final result = YieldMath.compute(
        ticker: 'NULLPRICES',
        currentPrice: 50,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 15), amount: 5),
        ],
        monthlyCloses: [
          MonthlyClose(monthStart: _utc(2025, 6), close: null),
          MonthlyClose(monthStart: _utc(2026, 5), close: null),
        ],
      );
      // DRIP falls back to currentPrice (50), so factor = 1 + 5/50 = 1.10.
      expect(result.compoundedGrossYield, closeTo(0.10, _eps));
      // Avg-price falls back to currentPrice when no valid closes.
      expect(result.avgPriceGrossYield, closeTo(5 / 50, _eps));
      // TWR contributes 0 because p0/p1 are null.
      expect(result.twrGross, 0);
    });

    test('single distribution, single close', () {
      final result = YieldMath.compute(
        ticker: 'SINGLE',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 15), amount: 4),
        ],
        monthlyCloses: [
          MonthlyClose(monthStart: _utc(2025, 12), close: 100),
        ],
      );
      expect(result.grossYield, closeTo(0.04, _eps));
      expect(result.compoundedGrossYield, closeTo(0.04, _eps));
      // No pair → TWR is the identity (factor=1 → 0).
      expect(result.twrGross, 0);
    });
  });

  group('YieldMath helpers', () {
    test('barIndexAt with empty bars returns -1', () {
      expect(YieldMath.barIndexAt(_utc(2025, 6), const []), -1);
    });
    test('barIndexAt picks latest bar on or before the date', () {
      final bars = [
        MonthlyClose(monthStart: _utc(2025, 6), close: 1),
        MonthlyClose(monthStart: _utc(2025, 9), close: 2),
        MonthlyClose(monthStart: _utc(2025, 12), close: 3),
      ];
      expect(YieldMath.barIndexAt(_utc(2025, 5), bars), -1);
      expect(YieldMath.barIndexAt(_utc(2025, 6), bars), 0);
      expect(YieldMath.barIndexAt(_utc(2025, 7), bars), 0);
      expect(YieldMath.barIndexAt(_utc(2025, 9), bars), 1);
      expect(YieldMath.barIndexAt(_utc(2026, 1), bars), 2);
    });
    test('priceAt walks back through null closes', () {
      final bars = [
        MonthlyClose(monthStart: _utc(2025, 6), close: 10),
        MonthlyClose(monthStart: _utc(2025, 9), close: null),
        MonthlyClose(monthStart: _utc(2025, 12), close: null),
      ];
      expect(YieldMath.priceAt(_utc(2025, 12, 15), bars), 10);
    });
  });
}

// Distribution timestamps from Yahoo are 13:30 UTC (US market 9:30 ET).
DateTime _ymagTs(int y, int m, int d) =>
    DateTime.utc(y, m, d, 13, 30);

// Monthly bar timestamps from Yahoo are first-of-month at ~04:00 UTC.
DateTime _ymagBar(int y, int m) => DateTime.utc(y, m, 1, 4, 0);

// Monthly closes from the real YMAG response captured 2026-05-25.
// 13 bars: 12 month-starts plus a partial-current-month bar.
final List<MonthlyClose> _ymagMonthlyCloses = [
  MonthlyClose(monthStart: _ymagBar(2025, 6), close: 15.25),
  MonthlyClose(monthStart: _ymagBar(2025, 7), close: 15.44),
  MonthlyClose(monthStart: _ymagBar(2025, 8), close: 15.24),
  MonthlyClose(monthStart: _ymagBar(2025, 9), close: 15.71),
  MonthlyClose(monthStart: _ymagBar(2025, 10), close: 15.39),
  MonthlyClose(monthStart: _ymagBar(2025, 11), close: 14.64),
  MonthlyClose(monthStart: _ymagBar(2025, 12), close: 14.23),
  MonthlyClose(monthStart: _ymagBar(2026, 1), close: 13.95),
  MonthlyClose(monthStart: _ymagBar(2026, 2), close: 12.81),
  MonthlyClose(monthStart: _ymagBar(2026, 3), close: 11.95),
  MonthlyClose(monthStart: _ymagBar(2026, 4), close: 12.80),
  MonthlyClose(monthStart: _ymagBar(2026, 5), close: 12.79),
  MonthlyClose(monthStart: DateTime.utc(2026, 5, 22, 20), close: 12.79),
];
