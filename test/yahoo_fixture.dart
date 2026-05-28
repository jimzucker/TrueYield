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

int _secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

/// Builds a Yahoo Finance chart JSON payload shaped like the real
/// `v8/finance/chart` response, for driving parser and widget-flow tests.
///
/// [closes] is index-aligned with [months]; a null entry models a gap bar.
/// [dividends] maps a pay date to an amount; pass empty for a non-payer.
String yahooChartJson({
  required double price,
  required List<DateTime> months,
  required List<double?> closes,
  Map<DateTime, double> dividends = const {},
}) {
  return json.encode({
    'chart': {
      'result': [
        {
          'meta': {'regularMarketPrice': price},
          'timestamp': [for (final m in months) _secs(m)],
          'indicators': {
            'quote': [
              {'close': closes},
            ],
          },
          'events': dividends.isEmpty
              ? null
              : {
                  'dividends': {
                    for (final e in dividends.entries)
                      '${_secs(e.key)}': {
                        'amount': e.value,
                        'date': _secs(e.key),
                      },
                  },
                },
        },
      ],
    },
  });
}

/// A Yahoo API error envelope (e.g. unknown/delisted symbol).
String yahooErrorJson(String description) {
  return json.encode({
    'chart': {
      'result': null,
      'error': {'code': 'Not Found', 'description': description},
    },
  });
}
