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

const _eps = 1e-9;

DateTime _utc(int y, [int m = 1, int d = 1]) => DateTime.utc(y, m, d);

double _sumNonNet(List<ReturnContribution> rows) =>
    rows.where((r) => !r.isNet).fold(0.0, (a, r) => a + r.value);

ReturnContribution _net(List<ReturnContribution> rows) =>
    rows.firstWhere((r) => r.isNet);

void main() {
  group('returnContributions — diverging return-bar data prep', () {
    test('the component values sum to the net return', () {
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
      final rows = returnContributions(r);
      // Net = after-tax value − cost, and the parts add up to it.
      expect(
        _net(rows).value,
        closeTo(r.nav - r.taxThisYear - r.capGainsTax - r.totalCost, _eps),
      );
      expect(_sumNonNet(rows), closeTo(_net(rows).value, 1e-6));
      // Income is a positive contribution; income tax is negative.
      expect(rows.firstWhere((r) => r.label == 'Income').value, greaterThan(0));
      expect(
        rows.firstWhere((r) => r.label == 'Income tax').value,
        lessThan(0),
      );
    });

    test('a sold long-term lot adds Realized G/L + Capital-gains tax rows', () {
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
      final rows = returnContributions(r);
      final labels = rows.map((r) => r.label).toList();
      expect(labels.contains('Realized G/L'), isTrue);
      expect(labels.contains('Capital-gains tax'), isTrue);
      expect(
        rows.firstWhere((r) => r.label == 'Capital-gains tax').value,
        lessThan(0),
      );
      expect(_sumNonNet(rows), closeTo(_net(rows).value, 1e-6));
    });

    test('a price loss makes the gain contribution negative', () {
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
      final rows = returnContributions(r);
      expect(
        rows.firstWhere((r) => r.label == 'Unrealized G/L').value,
        lessThan(0),
      );
      expect(_sumNonNet(rows), closeTo(_net(rows).value, 1e-6));
    });
  });
}
