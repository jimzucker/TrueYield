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
import 'package:true_yield/roc_data.dart';

void main() {
  group('rocForTicker (bundled 19a-1 ROC)', () {
    test(
      'looks up a known YieldMax fund, case- and whitespace-insensitive',
      () {
        // YMAG is a carried flagship value, stable across data refreshes.
        expect(rocForTicker('YMAG'), 71.0);
        expect(rocForTicker('ymag'), 71.0);
        expect(rocForTicker('  YMAG  '), 71.0);
      },
    );

    test('returns null for an unknown ticker', () {
      expect(rocForTicker('SCHD'), isNull);
      expect(rocForTicker('NOTAFUND'), isNull);
      expect(rocForTicker(''), isNull);
    });

    test('the bundled table is populated and stamped', () {
      expect(kRocByTicker, isNotEmpty);
      expect(kRocByTicker.length, greaterThan(20));
      expect(kRocDataAsOf, isNotEmpty);
      // Every value is a sane percentage.
      for (final v in kRocByTicker.values) {
        expect(v, inInclusiveRange(0, 100));
      }
    });
  });
}
