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

import 'yahoo_fixture.dart';

const _eps = 1e-9;

YieldResult _parse(String body, {String ticker = 'TEST'}) => parseYahooChart(
  body,
  ticker: ticker,
  federalPct: 32,
  statePct: 5,
  localPct: 0,
);

void main() {
  group('parseYahooChart — happy path', () {
    test('parses price, closes, and dividends into a qualifying result', () {
      final body = yahooChartJson(
        price: 80,
        months: [
          DateTime.utc(2025, 6),
          DateTime.utc(2025, 12),
          DateTime.utc(2026, 6),
        ],
        closes: [100, 90, 80],
        dividends: {DateTime.utc(2025, 12, 15): 5.0},
      );

      final r = _parse(body);

      expect(r.qualifies, isTrue);
      expect(r.currentPrice, closeTo(80, _eps));
      expect(r.sumDistributions, closeTo(5, _eps));
      expect(r.grossYield, closeTo(5 / 80, _eps));
      expect(r.distributions.length, 1);
      expect(r.priceBars.length, 3);
      // rocPct defaults to 0, so the whole distribution is taxable income;
      // combined 37% leaves a 0.63 after-tax fraction of the gross yield.
      expect(r.afterTaxYieldRoc, closeTo(5 / 80 * 0.63, _eps));
    });

    test('a null close in the quote array becomes a null PriceBar', () {
      final body = yahooChartJson(
        price: 50,
        months: [DateTime.utc(2025, 6), DateTime.utc(2025, 7)],
        closes: [100, null],
        dividends: {DateTime.utc(2025, 6, 10): 1.0},
      );

      final r = _parse(body);
      final july = r.priceBars.firstWhere(
        (c) => c.date == DateTime.utc(2025, 7),
      );
      expect(july.close, isNull);
    });

    test('a dividend entry missing its amount is skipped', () {
      // No usable dividends -> does not qualify.
      final body = yahooChartJson(
        price: 100,
        months: [DateTime.utc(2025, 6)],
        closes: [100],
      );
      final r = _parse(body);
      expect(r.qualifies, isFalse);
      expect(r.reason, 'no distributions in last 12 months');
    });
  });

  group('parseYahooChart — per-distribution ROC precedence', () {
    // One $5 payout on 2025-12-15; a 19a-1 payable date 2 days later carries 90%.
    final divDate = DateTime.utc(2025, 12, 15);
    final body = yahooChartJson(
      price: 80,
      months: [DateTime.utc(2025, 6), DateTime.utc(2026, 6)],
      closes: [100, 80],
      dividends: {divDate: 5.0},
    );
    int epoch(DateTime d) => d.toUtc().millisecondsSinceEpoch ~/ 1000;
    final divEpoch = epoch(divDate);
    final payableEpoch = epoch(DateTime.utc(2025, 12, 17)); // within tolerance

    test('history fills a row when there is no override', () {
      final r = parseYahooChart(
        body,
        ticker: 'TEST',
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        rocHistory: {payableEpoch: 90},
      );
      expect(r.distributions.single.rocPct, 90);
    });

    test('a user override beats history', () {
      final r = parseYahooChart(
        body,
        ticker: 'TEST',
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        rocByDivEpoch: {divEpoch: 50},
        rocHistory: {payableEpoch: 90},
      );
      expect(r.distributions.single.rocPct, 50);
    });

    test('no match leaves the row on the global default', () {
      final r = parseYahooChart(
        body,
        ticker: 'TEST',
        federalPct: 32,
        statePct: 5,
        localPct: 0,
        // A payable date 30 days off is outside the ~week tolerance.
        rocHistory: {epoch(DateTime.utc(2026, 1, 15)): 90},
      );
      expect(r.distributions.single.rocPct, isNull);
    });
  });

  group('parseYahooChart — error branches', () {
    test('API error envelope throws its description', () {
      final body = yahooErrorJson('No data found, symbol may be delisted');
      expect(
        () => _parse(body, ticker: 'BOGUS'),
        throwsA('No data found, symbol may be delisted'),
      );
    });

    test('empty result list throws "No data"', () {
      const body = '{"chart":{"result":[]}}';
      expect(() => _parse(body, ticker: 'X'), throwsA('No data for "X".'));
    });

    test('null result throws "No data"', () {
      const body = '{"chart":{"result":null}}';
      expect(() => _parse(body, ticker: 'X'), throwsA('No data for "X".'));
    });

    test('missing regularMarketPrice throws', () {
      const body = '{"chart":{"result":[{"meta":{}}]}}';
      expect(
        () => _parse(body, ticker: 'X'),
        throwsA('Missing current price for "X".'),
      );
    });
  });
}
