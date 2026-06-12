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

// ─── Shared formatting helpers (top-level so every widget reuses one copy) ───
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

// Sign colors resolve against the active theme so gains/losses stay legible in
// either brightness: dark keeps the original bright accents (no visual change),
// light falls back to a contrast-safe green and the scheme's error red.
Color gainColor(ThemeData t) => t.brightness == Brightness.dark
    ? Colors.greenAccent.shade400
    : const Color(0xFF1B7A3D);
Color lossColor(ThemeData t) => t.brightness == Brightness.dark
    ? Colors.redAccent.shade200
    : t.colorScheme.error;
Color signColor(ThemeData t, double v) => v < 0 ? lossColor(t) : gainColor(t);

// Group the integer part with commas so large figures read at a glance
// ("$1,250.00" not "$1250.00"). No intl dependency — a tiny manual grouper.
String _grouped(String fixed) {
  final dot = fixed.indexOf('.');
  final intPart = dot == -1 ? fixed : fixed.substring(0, dot);
  final frac = dot == -1 ? '' : fixed.substring(dot);
  final neg = intPart.startsWith('-');
  final digits = neg ? intPart.substring(1) : intPart;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}$buf$frac';
}

String _money(double v) => '\$${_grouped(v.toStringAsFixed(2))}';
// Per-share money needs 4 decimals (a $0.2611 payout mustn't collapse to $0.26).
String _money4(double v) => '\$${_grouped(v.toStringAsFixed(4))}';
// Whole-dollar money / signed money — used in the dense portfolio grid where
// pennies just cost space.
String _money0(double v) => '\$${_grouped(v.toStringAsFixed(0))}';
String _signedMoney0(double v) =>
    '${v < 0 ? '−' : '+'}\$${_grouped(v.abs().toStringAsFixed(0))}';
// Share count to 1 decimal, comma-grouped.
String fmtShares1(double v) => _grouped(v.toStringAsFixed(1));
String _signedMoney(double v) =>
    '${v < 0 ? '−' : '+'}\$${_grouped(v.abs().toStringAsFixed(2))}';
String _signedPct(double v) =>
    '${v < 0 ? '−' : '+'}${(v.abs() * 100).toStringAsFixed(1)}%';
String _pctPlain(double v) => '${(v * 100).toStringAsFixed(1)}%';

// Trim a trailing ".0" so 100.0 → "100" but 12.5 → "12.5"; null → "". Used for
// editable numeric fields (shares, ROC %) where extra decimals look noisy.
String fmtNum(double? v) => v == null
    ? ''
    : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString());

// A money value for a field: whole → no decimals, else 2 (e.g. an auto-filled cost).
String fmtMoneyField(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

// Share count for display: 2 decimals, comma-grouped (e.g. "1,234.56").
String fmtShares(double v) => _grouped(v.toStringAsFixed(2));

// "Jan '25" — compact month label for the reference grid columns.
String _monthLabel(DateTime d) =>
    "${_months[d.month - 1]} '${(d.year % 100).toString().padLeft(2, '0')}";

// "Dec 31, 2025" — readable date for the distribution/price lists.
String fmtDateHuman(DateTime d) =>
    '${_months[d.month - 1]} ${d.day}, ${d.year}';

// "Jan 2025" — readable month range endpoints.
String _fmtMonthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

// "May 28, 2026, 8:41 PM" — when a result was fetched (no intl dependency).
String fmtStamp(DateTime d) {
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${fmtDateHuman(d)}, $h12:$mm $ampm';
}

// True when fetchedAt and now fall on different calendar dates — i.e. the shown
// result was computed on an earlier day and its TTM window has since shifted.
bool isStale(DateTime fetchedAt, DateTime now) =>
    fetchedAt.year != now.year ||
    fetchedAt.month != now.month ||
    fetchedAt.day != now.day;
