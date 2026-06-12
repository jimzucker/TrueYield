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

/// Trailing return-of-capital % for [ticker] from the bundled YieldMax 19a-1
/// data ([kRocByTicker]), or null if the fund isn't known. Case-insensitive.
double? rocForTicker(String ticker) =>
    kRocByTicker[ticker.trim().toUpperCase()];

/// Per-payable-date ROC% history for [ticker] ([kRocByTickerByEpoch]), or null.
Map<int, double>? rocHistoryForTicker(String ticker) =>
    kRocByTickerByEpoch[ticker.trim().toUpperCase()];

/// Completed-year ROC% map for [ticker] ([kRocAnnualByTickerYear]), or null.
Map<int, double>? rocAnnualForTicker(String ticker) =>
    kRocAnnualByTickerYear[ticker.trim().toUpperCase()];

/// The settled full-year ROC% for a distribution in a COMPLETED calendar year
/// (8937 actual / 19a aggregate). Null for the current year or if unknown, so
/// the caller falls back to the live per-distribution value.
double? rocAnnualFor(Map<int, double>? annual, int divYear, int currentYear) {
  if (annual == null || divYear >= currentYear) return null;
  return annual[divYear];
}

/// The bundled per-distribution ROC% nearest a Yahoo dividend (ex-date) [epoch],
/// matched to its payable date in [hist] within a few days. Null if none close.
double? rocFromHistory(Map<int, double>? hist, int epoch) {
  if (hist == null || hist.isEmpty) return null;
  const tolerance = 6 * 86400; // ex-date ≈ payable date, within ~a week
  int? bestKey;
  var bestDist = tolerance + 1;
  for (final key in hist.keys) {
    final dist = (key - epoch).abs();
    if (dist < bestDist) {
      bestDist = dist;
      bestKey = key;
    }
  }
  return bestKey == null ? null : hist[bestKey];
}
