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

import 'package:flutter_test/flutter_test.dart';
import 'package:true_yield/main.dart';

import 'fixtures/tqqq_2026_05_27.dart';
import 'fixtures/ymag_2026_05_27.dart' as ymag_daily;

/// Closeness tolerance for yield comparisons. 1e-9 is tight enough to catch
/// any real math error and loose enough to survive harmless IEEE-754 drift.
const _eps = 1e-9;

DateTime _utc(int y, int m, [int d = 1]) => DateTime.utc(y, m, d);

// Re-derives the broker-DRIP + ROC fields from primitives so each fixture test
// guards that the published fields stay internally consistent (independent of
// the absolute magic numbers asserted alongside).
void _expectInvariants(YieldResult r, {required double rocPct}) {
  final incomeFrac = 1 - rocPct / 100;
  expect(r.dripShares, closeTo(r.compoundedGrossYield + 1, _eps));
  expect(r.nav, closeTo(r.dripShares * r.currentPrice, _eps));
  expect(r.incomeAmount, closeTo(r.sumDistributions * incomeFrac, 1e-9));
  expect(r.taxThisYear, closeTo(r.incomeAmount * r.combinedRate, _eps));
  expect(r.costBasis, closeTo(r.startPrice + r.incomeAmount, _eps));
  expect(r.unrealizedGL, closeTo(r.nav - r.costBasis, _eps));
  expect(
    r.afterTaxYieldRoc,
    closeTo((r.sumDistributions - r.taxThisYear) / r.currentPrice, _eps),
  );
  expect(
    r.totalReturnBeforeTax,
    closeTo((r.nav - r.startPrice) / r.startPrice, _eps),
  );
  expect(
    r.totalReturnAfterTax,
    closeTo((r.nav - r.taxThisYear - r.startPrice) / r.startPrice, _eps),
  );
}

void main() {
  group('YieldMath.compute — qualifying paths', () {
    test('simple two-distribution case at flat price, zero tax', () {
      // Flat $100 price, two $1 distributions → advertised 2%, DRIP slightly
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
        priceBars: [
          for (int m = 0; m < 13; m++)
            PriceBar(date: _utc(2025, 6 + m), close: 100),
        ],
      );

      expect(result.qualifies, isTrue);
      expect(result.sumDistributions, closeTo(2.00, _eps));
      expect(result.grossYield, closeTo(0.02, _eps));
      expect(
        result.compoundedGrossYield,
        closeTo((1 + 0.01) * (1 + 0.01) - 1, _eps),
      );
      expect(result.compoundedGrossYield, greaterThan(result.grossYield));
      expect(result.dripShares, closeTo((1 + 0.01) * (1 + 0.01), _eps));
      // Flat price + DRIP: the only "gain" is the compounding of reinvested
      // distributions — 1.0201 shares × $100 − $102 basis = $0.01.
      expect(result.unrealizedGL, closeTo(0.01, 1e-9));
      expect(result.totalReturnBeforeTax, closeTo(0.0201, _eps));
    });

    test('after-tax yield honours the ROC split', () {
      // rocPct 0 → whole distribution is taxable income.
      final allIncome = YieldMath.compute(
        ticker: 'TAX',
        currentPrice: 100,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 7, 15), amount: 10)],
        priceBars: [
          for (int m = 0; m < 13; m++)
            PriceBar(date: _utc(2025, 6 + m), close: 100),
        ],
      );
      expect(allIncome.grossYield, closeTo(0.10, _eps));
      expect(allIncome.afterTaxYieldRoc, closeTo(0.10 * 0.63, _eps));
      expect(allIncome.taxThisYear, closeTo(10 * 0.37, _eps));

      // rocPct 100 → return of capital, nothing taxed now.
      final allRoc = YieldMath.compute(
        ticker: 'TAX',
        currentPrice: 100,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 7, 15), amount: 10)],
        priceBars: [
          for (int m = 0; m < 13; m++)
            PriceBar(date: _utc(2025, 6 + m), close: 100),
        ],
        rocPct: 100,
      );
      expect(allRoc.taxThisYear, closeTo(0, _eps));
      expect(allRoc.afterTaxYieldRoc, closeTo(allRoc.grossYield, _eps));
    });

    test('price drop → DRIP < advertised, total return negative', () {
      // Price drops 100 → 80, single $5 distribution at mid-period (price 90).
      // DRIP shares = 1 + 5/90; NAV = shares × 80 < 100 start.
      final result = YieldMath.compute(
        ticker: 'DROP',
        currentPrice: 80,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 12, 15), amount: 5)],
        priceBars: [
          PriceBar(date: _utc(2025, 6), close: 100),
          PriceBar(date: _utc(2025, 12), close: 90),
          PriceBar(date: _utc(2026, 6), close: 80),
        ],
      );
      expect(result.grossYield, closeTo(5 / 80, _eps));
      expect(result.compoundedGrossYield, lessThan(result.grossYield));
      expect(result.compoundedGrossYield, closeTo(5 / 90, _eps));
      expect(result.totalReturnBeforeTax, lessThan(0));
    });

    test('price rise → DRIP > advertised, total return positive', () {
      // Price rises 80 → 100, single $5 distribution at mid-period (price 90).
      final result = YieldMath.compute(
        ticker: 'RISE',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 12, 15), amount: 5)],
        priceBars: [
          PriceBar(date: _utc(2025, 6), close: 80),
          PriceBar(date: _utc(2025, 12), close: 90),
          PriceBar(date: _utc(2026, 6), close: 100),
        ],
      );
      expect(result.compoundedGrossYield, greaterThan(result.grossYield));
      expect(result.compoundedGrossYield, closeTo(5 / 90, _eps));
      // NAV = (1 + 5/90) × 100 vs 80 start → positive.
      expect(result.totalReturnBeforeTax, greaterThan(0));
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
        priceBars: [
          for (int m = 0; m < 13; m++)
            PriceBar(date: _utc(2025, 6 + m), close: 100),
        ],
      );
      expect(result.distributions.first.date, _utc(2026, 1, 15));
      expect(result.distributions.last.date, _utc(2025, 7, 15));
    });

    test('YMAG-like monthly fixture matches pre-computed expected values', () {
      // Real YMAG response captured 2026-05-25, monthly bars. Combined rate 37%
      // (federal 32, state 5, local 0); rocPct 71 (YMAG is ~71% ROC).
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
        priceBars: _ymagPriceBars,
        rocPct: 71,
      );
      expect(result.qualifies, isTrue);
      expect(result.sumDistributions, closeTo(2.0050, 1e-6));
      expect(result.grossYield, closeTo(0.156763, 1e-5));
      expect(result.compoundedGrossYield, closeTo(0.141274, 1e-5));
      expect(result.startPrice, closeTo(15.25, 1e-9));
      // ROC-aware position economics (rocPct 71). Price fell 15.25 → 12.79, so
      // the position is underwater here even after DRIP.
      expect(result.incomeAmount, closeTo(0.581450, 1e-5));
      expect(result.taxThisYear, closeTo(0.215137, 1e-5));
      expect(result.costBasis, closeTo(15.831450, 1e-5));
      expect(result.unrealizedGL, closeTo(-1.234560, 1e-5));
      expect(result.totalReturnAfterTax, closeTo(-0.056937, 1e-5));
      _expectInvariants(result, rocPct: 71);
    });

    // Live daily-bar fixtures captured 2026-05-27. Expected values produced by
    // an independent Python port of YieldMath.compute (see tools/yield_ref.py).
    test('YMAG daily-bar fixture (2026-05-27) matches reference', () {
      final result = YieldMath.compute(
        ticker: 'YMAG',
        currentPrice: ymag_daily.kYMAGCurrentPrice,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: ymag_daily.kYMAGDistributions,
        priceBars: ymag_daily.kYMAGPriceBars,
        rocPct: 71,
      );
      expect(result.qualifies, isTrue);
      expect(result.sumDistributions, closeTo(6.5590, 1e-4));
      expect(result.grossYield, closeTo(0.511622, 1e-5));
      expect(result.compoundedGrossYield, closeTo(0.573860, 1e-5));
      // ROC-aware economics (rocPct 71): basis cut by ROC leaves an unrealized
      // gain even though the price fell — see roc-cost-basis-and-gl.
      expect(result.startPrice, closeTo(15.620000, 1e-5));
      expect(result.dripShares, closeTo(1.573860, 1e-5));
      expect(result.incomeAmount, closeTo(1.902110, 1e-5));
      expect(result.taxThisYear, closeTo(0.703781, 1e-5));
      expect(result.nav, closeTo(20.176884, 1e-5));
      expect(result.costBasis, closeTo(17.522110, 1e-5));
      expect(result.unrealizedGL, closeTo(2.654774, 1e-5));
      expect(result.afterTaxYieldRoc, closeTo(0.456725, 1e-5));
      expect(result.totalReturnBeforeTax, closeTo(0.291734, 1e-5));
      expect(result.totalReturnAfterTax, closeTo(0.246678, 1e-5));
      _expectInvariants(result, rocPct: 71);
    });

    test('TQQQ daily-bar fixture (2026-05-27) matches reference', () {
      final result = YieldMath.compute(
        ticker: 'TQQQ',
        currentPrice: kTQQQCurrentPrice,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: kTQQQDistributions,
        priceBars: kTQQQPriceBars,
        rocPct: 0,
      );
      expect(result.qualifies, isTrue);
      expect(result.sumDistributions, closeTo(0.3160, 1e-4));
      expect(result.grossYield, closeTo(0.003869, 1e-5));
      expect(result.compoundedGrossYield, closeTo(0.006937, 1e-5));
      // rocPct 0 (TQQQ pays ordinary income): basis = start + full distribution,
      // and the big total return is almost entirely price appreciation.
      expect(result.startPrice, closeTo(35.014999, 1e-5));
      expect(result.dripShares, closeTo(1.006937, 1e-5));
      expect(result.incomeAmount, closeTo(0.316000, 1e-5));
      expect(result.taxThisYear, closeTo(0.116920, 1e-5));
      expect(result.nav, closeTo(82.236522, 1e-5));
      expect(result.costBasis, closeTo(35.330999, 1e-5));
      expect(result.unrealizedGL, closeTo(46.905522, 1e-5));
      expect(result.afterTaxYieldRoc, closeTo(0.002438, 1e-5));
      expect(result.totalReturnBeforeTax, closeTo(1.348608, 1e-5));
      expect(result.totalReturnAfterTax, closeTo(1.345269, 1e-5));
      _expectInvariants(result, rocPct: 0);
    });

    test('print Statement (validated) for fixture tickers in app row order', () {
      // Recomputes from fixtures and prints the result panel the user sees on
      // the Calculate tab: the total-return statement (with its nested
      // components) plus the reference grid, for each fixture ticker.
      final ymag = YieldMath.compute(
        ticker: 'YMAG',
        currentPrice: ymag_daily.kYMAGCurrentPrice,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: ymag_daily.kYMAGDistributions,
        priceBars: ymag_daily.kYMAGPriceBars,
        rocPct: 71,
      );
      final tqqq = YieldMath.compute(
        ticker: 'TQQQ',
        currentPrice: kTQQQCurrentPrice,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: kTQQQDistributions,
        priceBars: kTQQQPriceBars,
        rocPct: 0,
      );

      String pct(double v) =>
          '${v < 0 ? '−' : '+'}${(v.abs() * 100).toStringAsFixed(2)}%';
      String plain(double v) => '${(v * 100).toStringAsFixed(2)}%';
      String money(double v) => '\$${v.toStringAsFixed(2)}';
      String signed(double v) =>
          '${v < 0 ? '−' : '+'}\$${v.abs().toStringAsFixed(2)}';

      final buf = StringBuffer()..writeln();
      for (final r in [ymag, tqqq]) {
        final afterTaxValue = r.nav - r.taxThisYear;
        buf
          ..writeln(
            'Statement (validated) — ${r.ticker}'
            '  [roc ${r.rocPct.toStringAsFixed(0)}%, tax '
            '${(r.combinedRate * 100).toStringAsFixed(0)}%]',
          )
          ..writeln('-' * 56)
          ..writeln(
            '${'Total return after tax'.padRight(34)}'
            '${pct(r.totalReturnAfterTax).padLeft(12)}',
          )
          ..writeln('  ${money(r.startPrice)} → ${money(afterTaxValue)}')
          ..writeln(
            '${'  Income (taxable)'.padRight(34)}'
            '${signed(r.incomeAmount).padLeft(12)}',
          )
          ..writeln(
            '${'  Unrealized G/L'.padRight(34)}'
            '${signed(r.unrealizedGL).padLeft(12)}',
          )
          ..writeln(
            '${'  Tax this year'.padRight(34)}'
            '${signed(-r.taxThisYear).padLeft(12)}',
          )
          ..writeln(
            '${'Advertised yield'.padRight(34)}'
            '${plain(r.grossYield).padLeft(12)}',
          )
          ..writeln(
            '${'After-tax yield'.padRight(34)}'
            '${plain(r.afterTaxYieldRoc).padLeft(12)}',
          )
          ..writeln('Reference                         start          now')
          ..writeln(
            '${'  Price'.padRight(28)}'
            '${money(r.startPrice).padLeft(12)}${money(r.currentPrice).padLeft(13)}',
          )
          ..writeln(
            '${'  Shares'.padRight(28)}'
            '${'1.00'.padLeft(12)}${r.dripShares.toStringAsFixed(2).padLeft(13)}',
          )
          ..writeln(
            '${'  Present Value'.padRight(28)}'
            '${money(r.startPrice).padLeft(12)}${money(r.nav).padLeft(13)}',
          )
          ..writeln(
            '${'  Cost basis'.padRight(28)}'
            '${money(r.startPrice).padLeft(12)}${money(r.costBasis).padLeft(13)}',
          )
          ..writeln(
            '${'  Unrealized G/L'.padRight(28)}'
            '${'—'.padLeft(12)}${signed(r.unrealizedGL).padLeft(13)}',
          )
          ..writeln();
      }
      // ignore: avoid_print
      print(buf.toString());
    });
  });

  group('YieldMath.compute — non-qualifying / edge cases', () {
    test('no distributions → does not qualify, prices preserved', () {
      final closes = [
        PriceBar(date: _utc(2025, 6), close: 100),
        PriceBar(date: _utc(2026, 5), close: 110),
      ];
      final result = YieldMath.compute(
        ticker: 'BRK-B',
        currentPrice: 486.38,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: const [],
        priceBars: closes,
      );
      expect(result.qualifies, isFalse);
      expect(result.reason, equals('no distributions in last 12 months'));
      expect(result.grossYield, 0);
      expect(result.compoundedGrossYield, 0);
      expect(result.totalReturnAfterTax, 0);
      // Prices are still surfaced for the Prices tab.
      expect(result.priceBars.length, closes.length);
      expect(result.distributions, isEmpty);
    });

    test('all price-bar closes null → falls back to currentPrice for DRIP', () {
      final result = YieldMath.compute(
        ticker: 'NULLPRICES',
        currentPrice: 50,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 12, 15), amount: 5)],
        priceBars: [
          PriceBar(date: _utc(2025, 6), close: null),
          PriceBar(date: _utc(2026, 5), close: null),
        ],
      );
      // DRIP falls back to currentPrice (50), so factor = 1 + 5/50 = 1.10.
      expect(result.compoundedGrossYield, closeTo(0.10, _eps));
      // startPrice falls back to currentPrice (50): NAV = 1.10 × 50 = 55,
      // total return before tax = (55 − 50) / 50 = 0.10.
      expect(result.totalReturnBeforeTax, closeTo(0.10, _eps));
    });

    test('single distribution, single close', () {
      final result = YieldMath.compute(
        ticker: 'SINGLE',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [DistributionEntry(date: _utc(2025, 12, 15), amount: 4)],
        priceBars: [PriceBar(date: _utc(2025, 12), close: 100)],
      );
      expect(result.grossYield, closeTo(0.04, _eps));
      expect(result.compoundedGrossYield, closeTo(0.04, _eps));
      // startPrice = 100: NAV = 1.04 × 100 = 104, (104 − 100) / 100 = 0.04.
      expect(result.totalReturnBeforeTax, closeTo(0.04, _eps));
    });
  });

  group('YieldMath helpers', () {
    test('barIndexAt with empty bars returns -1', () {
      expect(YieldMath.barIndexAt(_utc(2025, 6), const []), -1);
    });
    test('barIndexAt picks latest bar on or before the date', () {
      final bars = [
        PriceBar(date: _utc(2025, 6), close: 1),
        PriceBar(date: _utc(2025, 9), close: 2),
        PriceBar(date: _utc(2025, 12), close: 3),
      ];
      expect(YieldMath.barIndexAt(_utc(2025, 5), bars), -1);
      expect(YieldMath.barIndexAt(_utc(2025, 6), bars), 0);
      expect(YieldMath.barIndexAt(_utc(2025, 7), bars), 0);
      expect(YieldMath.barIndexAt(_utc(2025, 9), bars), 1);
      expect(YieldMath.barIndexAt(_utc(2026, 1), bars), 2);
    });
    test('priceAt walks back through null closes', () {
      final bars = [
        PriceBar(date: _utc(2025, 6), close: 10),
        PriceBar(date: _utc(2025, 9), close: null),
        PriceBar(date: _utc(2025, 12), close: null),
      ];
      expect(YieldMath.priceAt(_utc(2025, 12, 15), bars), 10);
    });
    test(
      'priceAt walks forward when the start bar and earlier bars are null',
      () {
        // Date precedes all bars (barIndexAt == -1 → start 0); bar[0] is null,
        // so the forward walk returns the first later non-null close.
        final bars = [
          PriceBar(date: _utc(2025, 6), close: null),
          PriceBar(date: _utc(2025, 9), close: 20),
        ];
        expect(YieldMath.priceAt(_utc(2025, 5, 1), bars), 20);
      },
    );
    test('priceAt returns null when every bar is null', () {
      final bars = [
        PriceBar(date: _utc(2025, 6), close: null),
        PriceBar(date: _utc(2025, 9), close: null),
      ];
      expect(YieldMath.priceAt(_utc(2025, 7, 1), bars), isNull);
    });
  });

  group('YieldMath.compute — additional edge cases', () {
    test(
      'distribution dated before the first bar uses the first bar price',
      () {
        // priceAt falls back to the first available bar (50), not currentPrice
        // (100): DRIP factor = 1 + 5/50 = 1.10, distinguishing the two paths.
        final r = YieldMath.compute(
          ticker: 'EARLY',
          currentPrice: 100,
          federalPct: 0,
          statePct: 0,
          localPct: 0,
          distributions: [DistributionEntry(date: _utc(2025, 5, 1), amount: 5)],
          priceBars: [
            PriceBar(date: _utc(2025, 6), close: 50),
            PriceBar(date: _utc(2025, 12), close: 100),
          ],
        );
        expect(r.compoundedGrossYield, closeTo(0.10, _eps));
        expect(r.startPrice, closeTo(50, _eps)); // first valid close, not 100
      },
    );

    test(
      'combined rate of 100% zeroes after-tax yield; above 100% goes negative',
      () {
        // rocPct 0 → all income taxable. combined 100% → tax == distributions.
        final full = YieldMath.compute(
          ticker: 'FULLTAX',
          currentPrice: 100,
          federalPct: 70,
          statePct: 25,
          localPct: 5,
          distributions: [
            DistributionEntry(date: _utc(2025, 12, 10), amount: 8),
          ],
          priceBars: [
            PriceBar(date: _utc(2025, 12), close: 100),
            PriceBar(date: _utc(2026, 1), close: 100),
          ],
        );
        expect(full.grossYield, closeTo(0.08, _eps));
        expect(full.afterTaxYieldRoc, closeTo(0, _eps));

        // combined 1.2 → afterTaxYieldRoc = (10 − 10×1.2) / 100 = −0.02.
        final over = YieldMath.compute(
          ticker: 'OVERTAX',
          currentPrice: 100,
          federalPct: 80,
          statePct: 40,
          localPct: 0,
          distributions: [
            DistributionEntry(date: _utc(2025, 12, 10), amount: 10),
          ],
          priceBars: [
            PriceBar(date: _utc(2025, 12), close: 100),
            PriceBar(date: _utc(2026, 1), close: 100),
          ],
        );
        expect(over.afterTaxYieldRoc, closeTo(-0.02, _eps));
      },
    );

    test('rocPct outside 0–100 is clamped', () {
      final hi = YieldMath.compute(
        ticker: 'ROCHI',
        currentPrice: 100,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 10), amount: 10),
        ],
        priceBars: [PriceBar(date: _utc(2025, 12), close: 100)],
        rocPct: 150,
      );
      // Clamped to 100% ROC → no taxable income, no tax this year.
      expect(hi.incomeAmount, closeTo(0, _eps));
      expect(hi.taxThisYear, closeTo(0, _eps));

      final lo = YieldMath.compute(
        ticker: 'ROCLO',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 12, 10), amount: 10),
        ],
        priceBars: [PriceBar(date: _utc(2025, 12), close: 100)],
        rocPct: -50,
      );
      // Clamped to 0% ROC → the whole distribution is taxable income.
      expect(lo.incomeAmount, closeTo(10, _eps));
    });
  });

  group('YieldMath.compute — lots', () {
    // A flat-$100 year with two $1 distributions, used across the lot tests so
    // expected numbers are derivable by hand.
    List<DistributionEntry> twoDists() => [
      DistributionEntry(date: _utc(2025, 7, 15), amount: 1.00),
      DistributionEntry(date: _utc(2026, 1, 15), amount: 1.00),
    ];
    List<PriceBar> flatBars() => [
      for (int m = 0; m < 13; m++)
        PriceBar(date: _utc(2025, 6 + m), close: 100),
    ];

    test('no lots ≡ a single default lot (epoch-0, 1 share)', () {
      YieldResult run(List<Lot>? lots) => YieldMath.compute(
        ticker: 'EQ',
        currentPrice: 100,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: twoDists(),
        priceBars: flatBars(),
        rocPct: 71,
        lots: lots,
      );
      final implicit = run(null);
      final explicit = run([
        Lot(
          buyDate: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          mode: LotSizeMode.shares,
          amount: 1,
        ),
      ]);
      // The default lot must reproduce the original per-share numbers exactly.
      expect(explicit.nav, closeTo(implicit.nav, _eps));
      expect(explicit.costBasis, closeTo(implicit.costBasis, _eps));
      expect(explicit.incomeAmount, closeTo(implicit.incomeAmount, _eps));
      expect(explicit.taxThisYear, closeTo(implicit.taxThisYear, _eps));
      expect(explicit.dripShares, closeTo(implicit.dripShares, _eps));
      expect(
        explicit.totalReturnAfterTax,
        closeTo(implicit.totalReturnAfterTax, _eps),
      );
      expect(implicit.isSinglePortfolioLot, isTrue);
    });

    test('two share lots with different buy dates aggregate by hand', () {
      // Lot A (10 sh, bought before both dists): factor (1.01)^2.
      // Lot B (10 sh, bought after the first dist): factor 1.01 (one dist).
      final r = YieldMath.compute(
        ticker: 'TWO',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: twoDists(),
        priceBars: flatBars(),
        lots: [
          Lot(buyDate: _utc(2025, 6, 1), mode: LotSizeMode.shares, amount: 10),
          Lot(buyDate: _utc(2025, 8, 1), mode: LotSizeMode.shares, amount: 10),
        ],
      );
      expect(r.isSinglePortfolioLot, isFalse);
      expect(r.lots.length, 2);
      expect(r.totalCost, closeTo(2000, _eps));
      // Lot A: 10×1.0201 = 10.201; Lot B: 10×1.01 = 10.10 → 20.301 shares.
      expect(r.dripShares, closeTo(20.301, _eps));
      expect(r.nav, closeTo(2030.10, 1e-9));
      // Income (0 tax): A earns $2/sh on 10 sh, B earns $1/sh on 10 sh = 30.
      expect(r.incomeAmount, closeTo(30, _eps));
      expect(r.taxThisYear, closeTo(0, _eps));
      // G/L is nav − cost basis (reinvested income is a basis add, not a gain):
      // 2030.10 − (1020 + 1010) = 0.10.
      expect(r.unrealizedGL, closeTo(0.10, 1e-9));
      // Return on cost includes the reinvested income: 30.10 / 2000.
      expect(r.totalReturnBeforeTax, closeTo(30.10 / 2000, _eps));
    });

    test('a dollar lot converts to shares at the buy-date price', () {
      final r = YieldMath.compute(
        ticker: 'USD',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: twoDists(),
        priceBars: flatBars(),
        lots: [
          Lot(
            buyDate: _utc(2025, 6, 1),
            mode: LotSizeMode.dollars,
            amount: 1000,
          ),
        ],
      );
      // $1000 ÷ $100 = 10 initial shares.
      expect(r.lots.single.initialShares, closeTo(10, _eps));
      expect(r.totalCost, closeTo(1000, _eps));
    });

    test('a lot bought after every distribution earns no income', () {
      final r = YieldMath.compute(
        ticker: 'LATE',
        currentPrice: 100,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: twoDists(),
        priceBars: flatBars(),
        lots: [
          Lot(buyDate: _utc(2026, 5, 1), mode: LotSizeMode.shares, amount: 10),
        ],
      );
      final lot = r.lots.single;
      expect(lot.incomeAmount, closeTo(0, _eps));
      expect(lot.finalShares, closeTo(10, _eps)); // no DRIP growth
      expect(r.taxThisYear, closeTo(0, _eps));
      expect(r.totalReturnBeforeTax, closeTo(0, _eps)); // flat price
    });

    test('per-distribution ROC overrides the global default', () {
      final r = YieldMath.compute(
        ticker: 'PDROC',
        currentPrice: 100,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        distributions: [
          DistributionEntry(date: _utc(2025, 7, 15), amount: 1.00, rocPct: 0),
          DistributionEntry(date: _utc(2026, 1, 15), amount: 1.00, rocPct: 100),
        ],
        priceBars: flatBars(),
        rocPct: 50, // ignored — both rows carry explicit ROC
      );
      // Only the 0%-ROC payout is taxable income → $1 per share.
      expect(r.perShareIncome, closeTo(1.0, _eps));
      expect(r.incomeAmount, closeTo(1.0, _eps));
      expect(r.sumDistributions, closeTo(2.0, _eps));
    });

    test('print Portfolio (validated) — YMAG, three lots in app row order', () {
      // Three lots at different buy dates, sized in shares and dollars. Mirrors
      // tools/yield_ref.py portfolio_demo so the two can be eyeballed together.
      final r = YieldMath.compute(
        ticker: 'YMAG',
        currentPrice: ymag_daily.kYMAGCurrentPrice,
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        distributions: ymag_daily.kYMAGDistributions,
        priceBars: ymag_daily.kYMAGPriceBars,
        rocPct: 71,
        lots: [
          Lot(buyDate: _utc(2025, 6, 1), mode: LotSizeMode.shares, amount: 100),
          Lot(
            buyDate: _utc(2025, 12, 1),
            mode: LotSizeMode.dollars,
            amount: 5000,
          ),
          Lot(buyDate: _utc(2026, 3, 1), mode: LotSizeMode.shares, amount: 50),
        ],
      );

      // Aggregates must equal the sum of the per-lot breakdown.
      expect(r.lots.length, 3);
      expect(r.lots.fold<double>(0, (s, l) => s + l.nav), closeTo(r.nav, 1e-6));
      expect(
        r.lots.fold<double>(0, (s, l) => s + l.cost),
        closeTo(r.totalCost, 1e-6),
      );

      const mon = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      String monthLabel(DateTime d) =>
          "${mon[d.month - 1]} '${(d.year % 100).toString().padLeft(2, '0')}";
      String money(double v) => '\$${v.toStringAsFixed(2)}';
      String signed(double v) =>
          '${v < 0 ? '−' : '+'}\$${v.abs().toStringAsFixed(2)}';
      final buf = StringBuffer()
        ..writeln()
        ..writeln('Portfolio (validated) — YMAG  [roc 71%, tax 37%]')
        ..writeln('-' * 60)
        ..writeln(
          '${'Lot'.padRight(10)}${'Shares'.padLeft(16)}'
          '${'Cost'.padLeft(11)}${'Value'.padLeft(11)}${'G/L'.padLeft(11)}',
        );
      for (final l in r.lots) {
        final sh =
            '${l.initialShares.toStringAsFixed(2)}→${l.finalShares.toStringAsFixed(2)}';
        buf.writeln(
          '${monthLabel(l.buyDate).padRight(10)}${sh.padLeft(16)}'
          '${money(l.cost).padLeft(11)}${money(l.nav).padLeft(11)}'
          '${signed(l.unrealizedGL).padLeft(11)}',
        );
      }
      final ti = r.lots.fold<double>(0, (s, l) => s + l.initialShares);
      final tf = r.lots.fold<double>(0, (s, l) => s + l.finalShares);
      buf
        ..writeln(
          '${'Total'.padRight(10)}'
          '${'${ti.toStringAsFixed(2)}→${tf.toStringAsFixed(2)}'.padLeft(16)}'
          '${money(r.totalCost).padLeft(11)}${money(r.nav).padLeft(11)}'
          '${signed(r.unrealizedGL).padLeft(11)}',
        )
        ..writeln()
        ..writeln(
          'Total return after tax: '
          '${(r.totalReturnAfterTax * 100).toStringAsFixed(2)}%',
        );
      // ignore: avoid_print
      print(buf.toString());
    });
  });

  group('yahooRangeFor', () {
    final now = DateTime.utc(2026, 6, 1);
    DateTime ago(int days) => now.subtract(Duration(days: days));
    test('rounds the buy span up to a Yahoo range', () {
      expect(yahooRangeFor(ago(100), now), '1y');
      expect(yahooRangeFor(ago(366), now), '1y');
      expect(yahooRangeFor(ago(367), now), '2y');
      expect(yahooRangeFor(ago(731), now), '2y');
      expect(yahooRangeFor(ago(732), now), '5y');
      expect(yahooRangeFor(ago(1827), now), '5y');
      expect(yahooRangeFor(ago(1828), now), '10y');
      expect(yahooRangeFor(ago(3653), now), '10y');
      expect(yahooRangeFor(ago(3654), now), 'max');
    });
  });
}

// Distribution timestamps from Yahoo are 13:30 UTC (US market 9:30 ET).
DateTime _ymagTs(int y, int m, int d) => DateTime.utc(y, m, d, 13, 30);

// Bar timestamps from the original 1mo YMAG capture are first-of-month at ~04:00 UTC.
DateTime _ymagBar(int y, int m) => DateTime.utc(y, m, 1, 4, 0);

// Price bars from the real YMAG response captured 2026-05-25.
final List<PriceBar> _ymagPriceBars = [
  PriceBar(date: _ymagBar(2025, 6), close: 15.25),
  PriceBar(date: _ymagBar(2025, 7), close: 15.44),
  PriceBar(date: _ymagBar(2025, 8), close: 15.24),
  PriceBar(date: _ymagBar(2025, 9), close: 15.71),
  PriceBar(date: _ymagBar(2025, 10), close: 15.39),
  PriceBar(date: _ymagBar(2025, 11), close: 14.64),
  PriceBar(date: _ymagBar(2025, 12), close: 14.23),
  PriceBar(date: _ymagBar(2026, 1), close: 13.95),
  PriceBar(date: _ymagBar(2026, 2), close: 12.81),
  PriceBar(date: _ymagBar(2026, 3), close: 11.95),
  PriceBar(date: _ymagBar(2026, 4), close: 12.80),
  PriceBar(date: _ymagBar(2026, 5), close: 12.79),
  PriceBar(date: DateTime.utc(2026, 5, 22, 20), close: 12.79),
];
