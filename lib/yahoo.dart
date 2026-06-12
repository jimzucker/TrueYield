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

/// Optional CORS proxy origin for the Yahoo Finance endpoint, supplied at build
/// time via `--dart-define=YAHOO_PROXY=<origin>` (no trailing slash). It is used
/// only on the web build, where the browser enforces CORS and Yahoo's endpoint
/// sends no `Access-Control-Allow-Origin` header; native builds always call
/// Yahoo directly. Empty (the default) means "no proxy". See proxy/ for a
/// ready-to-deploy Cloudflare Worker.
const String kYahooProxy = String.fromEnvironment('YAHOO_PROXY');

/// Yahoo Finance chart API origin (no proxy). Native builds always hit this.
const String kYahooDirect = 'https://query2.finance.yahoo.com';

/// Resolves the chart-API base origin. The proxy is used **only on web** and
/// only when one is configured; every native target (iOS/Android/desktop) and
/// any web build without a proxy goes straight to Yahoo. Pure (takes [isWeb] as
/// a parameter) so both branches are unit-testable — `kIsWeb` is a
/// compile-time const that can't be toggled in a test.
String resolveYahooBase({required bool isWeb, required String proxy}) =>
    (isWeb && proxy.isNotEmpty) ? proxy : kYahooDirect;

/// Base origin for the Yahoo chart API: the CORS proxy on web (when configured),
/// Yahoo directly otherwise. The proxy forwards by path, so the rest of the URL
/// is identical either way.
String get yahooBase => resolveYahooBase(isWeb: kIsWeb, proxy: kYahooProxy);

/// Parses a Yahoo Finance chart JSON [responseBody] into a [YieldResult].
///
/// Pure: no network and no clock, so it is exercised directly in tests with
/// canned payloads. Throws a human-readable [String] on an API error envelope,
/// empty results, or a missing current price.
YieldResult parseYahooChart(
  String responseBody, {
  required String ticker,
  required double federalPct,
  required double statePct,
  required double localPct,
  double rocPct = 0,
  // Long-term capital-gains federal rate; effective LT rate adds State+Local.
  double ltGainsPct = 15,
  // Per-distribution ROC overrides keyed by the Yahoo dividend epoch (seconds).
  // A matched entry overrides the global [rocPct] for that payout.
  Map<int, double>? rocByDivEpoch,
  // Bundled per-payable-date ROC% history (from 19a-1 notices), keyed by payable
  // epoch. Precedence per payout: user override > completed-year actual >
  // history > global [rocPct].
  Map<int, double>? rocHistory,
  // Settled full-year ROC% (8937 actual / 19a aggregate), keyed by year. Applied
  // to distributions in a COMPLETED calendar year (year < [currentYear]).
  Map<int, double>? rocAnnual,
  int currentYear = 0,
  // One purchase per lot; null/empty → the single default lot.
  List<Lot>? lots,
}) {
  final body = json.decode(responseBody) as Map<String, dynamic>;
  final chart = body['chart'] as Map<String, dynamic>?;
  final err = chart?['error'];
  if (err != null) {
    throw err is Map ? (err['description'] ?? err.toString()) : err.toString();
  }
  final results = chart?['result'] as List<dynamic>?;
  if (results == null || results.isEmpty) {
    throw 'No data for "$ticker".';
  }
  final r0 = results.first as Map<String, dynamic>;
  final meta = r0['meta'] as Map<String, dynamic>?;
  final price = (meta?['regularMarketPrice'] as num?)?.toDouble();
  if (price == null) {
    throw 'Missing current price for "$ticker".';
  }

  final timestamps =
      (r0['timestamp'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList() ??
      const <int>[];
  final closes =
      ((r0['indicators']?['quote'] as List<dynamic>?)?.first
              as Map<String, dynamic>?)?['close']
          as List<dynamic>? ??
      const [];

  final priceBars = <PriceBar>[
    for (int i = 0; i < timestamps.length; i++)
      PriceBar(
        date: DateTime.fromMillisecondsSinceEpoch(
          timestamps[i] * 1000,
          isUtc: true,
        ),
        close: (i < closes.length && closes[i] is num)
            ? (closes[i] as num).toDouble()
            : null,
      ),
  ];

  final events = r0['events'] as Map<String, dynamic>?;
  final dividends = events?['dividends'] as Map<String, dynamic>?;
  final distributionList = <DistributionEntry>[];
  if (dividends != null) {
    for (final entry in dividends.values) {
      final m = entry as Map<String, dynamic>;
      final amt = (m['amount'] as num?)?.toDouble();
      final divTs = (m['date'] as num?)?.toInt();
      if (amt == null || divTs == null) continue;
      final divDate = DateTime.fromMillisecondsSinceEpoch(
        divTs * 1000,
        isUtc: true,
      );
      distributionList.add(
        DistributionEntry(
          date: divDate,
          amount: amt,
          rocPct:
              rocByDivEpoch?[divTs] ??
              rocAnnualFor(rocAnnual, divDate.year, currentYear) ??
              rocFromHistory(rocHistory, divTs),
        ),
      );
    }
  }

  return YieldMath.compute(
    ticker: ticker,
    currentPrice: price,
    federalPct: federalPct,
    statePct: statePct,
    localPct: localPct,
    distributions: distributionList,
    priceBars: priceBars,
    rocPct: rocPct,
    ltGainsPct: ltGainsPct,
    lots: lots,
  );
}

/// Smallest Yahoo `range` value that covers [earliestBuy] back from [now].
/// The chart endpoint only accepts these discrete spans, so we round up. Pure
/// (takes [now]) so it's unit-testable without the clock.
String yahooRangeFor(DateTime earliestBuy, DateTime now) {
  final days = now.difference(earliestBuy).inDays;
  if (days <= 366) return '1y';
  if (days <= 731) return '2y';
  if (days <= 1827) return '5y';
  if (days <= 3653) return '10y';
  return 'max';
}

/// Most recent weekday on or before [now] (a stand-in for the last trading day;
/// ignores market holidays). Used as the default buy date for a new lot. Pure.
DateTime lastTradingDay(DateTime now) {
  var d = DateTime.utc(now.year, now.month, now.day);
  while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
    d = d.subtract(const Duration(days: 1));
  }
  return d;
}

/// Turn a fetch/parse failure into a short, specific message. The pieces it
/// disambiguates: a network failure (`http.ClientException` or a socket error),
/// an HTTP status (the fetch layer throws `'HTTP <code>'`), an unknown symbol or
/// missing price (`parseYahooChart` throws Yahoo's own human-readable text), and
/// anything else (passed through). Pure + testable.
String friendlyFetchError(Object e, String ticker) {
  if (e is http.ClientException) {
    return 'Couldn’t reach Yahoo — check your connection.';
  }
  final s = e.toString();
  final low = s.toLowerCase();
  if (low.contains('failed host lookup') ||
      low.contains('socketexception') ||
      low.contains('connection') ||
      low.contains('timed out')) {
    return 'Couldn’t reach Yahoo — check your connection.';
  }
  if (s.startsWith('HTTP')) {
    return 'Yahoo returned an error ($s). Try again in a moment.';
  }
  if (low.contains('missing current price')) {
    return 'No current price for “$ticker” right now — try again later.';
  }
  if (low.contains('no data') ||
      low.contains('not found') ||
      low.contains('delisted') ||
      low.contains('may be delisted')) {
    return '“$ticker” not found — check the symbol.';
  }
  return 'Lookup failed: $e';
}
