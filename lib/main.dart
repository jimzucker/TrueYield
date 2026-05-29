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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  runApp(const TrueYieldApp());
}

class TrueYieldApp extends StatelessWidget {
  const TrueYieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrueYield',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const YieldScreen(),
    );
  }
}

class DistributionEntry {
  final DateTime date;
  final double amount;
  const DistributionEntry({required this.date, required this.amount});
}

class PriceBar {
  final DateTime date;
  final double? close;
  const PriceBar({required this.date, required this.close});
}

class YieldResult {
  final String ticker;
  final double currentPrice;
  final double sumDistributions;
  // Advertised yield: sum(dist) / current_price.
  final double grossYield;
  // Share growth from a real broker DRIP of the full gross distribution,
  // starting from 1 share: prod(1 + d_t / P_t) - 1. dripShares = this + 1.
  final double compoundedGrossYield;
  final double dripShares;

  // Position economics under the broker-DRIP + return-of-capital model.
  // startPrice ≈ price one year ago (first valid close); combinedRate is the
  // total tax fraction; rocPct is the share of distributions that is return of
  // capital (untaxed now, but it lowers basis — see roc-cost-basis-and-gl memory).
  final double startPrice;
  final double combinedRate;
  final double rocPct;
  // incomeAmount = taxable income portion of distributions = sum * (1 - roc).
  final double incomeAmount;
  // Tax owed this year, on the income portion only.
  final double taxThisYear;
  // nav = dripShares * currentPrice (what the position is worth now).
  final double nav;
  // Tax basis = original cost + reinvested INCOME. Reinvesting the ROC portion
  // adds basis but ROC also lowers basis by the same amount, so they cancel:
  // costBasis = startPrice + incomeAmount.
  final double costBasis;
  // unrealizedGL = nav - costBasis (taxed as capital gains only when sold).
  final double unrealizedGL;
  // ROC-aware after-tax distribution yield: (sum - taxThisYear) / currentPrice.
  final double afterTaxYieldRoc;
  // Total return on the original cost, before and after this year's tax.
  final double totalReturnBeforeTax;
  final double totalReturnAfterTax;

  final List<DistributionEntry> distributions;
  final List<PriceBar> priceBars;
  final bool qualifies;
  final String? reason;

  const YieldResult({
    required this.ticker,
    required this.currentPrice,
    required this.sumDistributions,
    required this.grossYield,
    required this.compoundedGrossYield,
    required this.dripShares,
    required this.startPrice,
    required this.combinedRate,
    required this.rocPct,
    required this.incomeAmount,
    required this.taxThisYear,
    required this.nav,
    required this.costBasis,
    required this.unrealizedGL,
    required this.afterTaxYieldRoc,
    required this.totalReturnBeforeTax,
    required this.totalReturnAfterTax,
    required this.distributions,
    required this.priceBars,
    required this.qualifies,
    this.reason,
  });

  factory YieldResult.doesNotQualify({
    required String ticker,
    required double currentPrice,
    required String reason,
    List<PriceBar> priceBars = const [],
  }) {
    return YieldResult(
      ticker: ticker,
      currentPrice: currentPrice,
      sumDistributions: 0,
      grossYield: 0,
      compoundedGrossYield: 0,
      dripShares: 1,
      startPrice: currentPrice,
      combinedRate: 0,
      rocPct: 0,
      incomeAmount: 0,
      taxThisYear: 0,
      nav: currentPrice,
      costBasis: currentPrice,
      unrealizedGL: 0,
      afterTaxYieldRoc: 0,
      totalReturnBeforeTax: 0,
      totalReturnAfterTax: 0,
      distributions: const [],
      priceBars: priceBars,
      qualifies: false,
      reason: reason,
    );
  }
}

/// Pure-function yield math. No Flutter, no HTTP, no DateTime.now().
/// All inputs are explicit so this class is trivially testable.
class YieldMath {
  static YieldResult compute({
    required String ticker,
    required double currentPrice,
    required double federalPct,
    required double statePct,
    required double localPct,
    required List<DistributionEntry> distributions,
    required List<PriceBar> priceBars,
    double rocPct = 0,
  }) {
    final sortedCloses = [...priceBars]
      ..sort((a, b) => a.date.compareTo(b.date));

    if (distributions.isEmpty) {
      return YieldResult.doesNotQualify(
        ticker: ticker,
        currentPrice: currentPrice,
        reason: 'no distributions in last 12 months',
        priceBars: sortedCloses,
      );
    }

    final combined = (federalPct + statePct + localPct) / 100.0;
    final ascDist = [...distributions]
      ..sort((a, b) => a.date.compareTo(b.date));

    double sum = 0;
    double compoundFactorGross = 1;

    for (final d in ascDist) {
      sum += d.amount;
      final priceAtDiv = priceAt(d.date, sortedCloses) ?? currentPrice;
      compoundFactorGross *= 1 + d.amount / priceAtDiv;
    }

    final grossYield = sum / currentPrice;
    final dripShares = compoundFactorGross;

    // First valid close ≈ price one year ago; falls back to currentPrice if
    // every bar's close is null.
    double startPrice = currentPrice;
    for (final bar in sortedCloses) {
      final c = bar.close;
      if (c != null && c > 0) {
        startPrice = c;
        break;
      }
    }

    // Broker-DRIP + return-of-capital economics. Only the income portion is
    // taxed now; ROC lowers basis (and cancels the basis added by reinvesting
    // it), so basis = startPrice + reinvested income. See roc-cost-basis-and-gl.
    final rocFrac = (rocPct / 100.0).clamp(0.0, 1.0);
    final incomeAmount = sum * (1 - rocFrac);
    final taxThisYear = incomeAmount * combined;
    final nav = dripShares * currentPrice;
    final costBasis = startPrice + incomeAmount;
    final unrealizedGL = nav - costBasis;
    final afterTaxYieldRoc = (sum - taxThisYear) / currentPrice;
    final totalReturnBeforeTax = (nav - startPrice) / startPrice;
    final totalReturnAfterTax = (nav - taxThisYear - startPrice) / startPrice;

    final descDist = [...distributions]
      ..sort((a, b) => b.date.compareTo(a.date));

    return YieldResult(
      ticker: ticker,
      currentPrice: currentPrice,
      sumDistributions: sum,
      grossYield: grossYield,
      compoundedGrossYield: compoundFactorGross - 1,
      dripShares: dripShares,
      startPrice: startPrice,
      combinedRate: combined,
      rocPct: rocPct,
      incomeAmount: incomeAmount,
      taxThisYear: taxThisYear,
      nav: nav,
      costBasis: costBasis,
      unrealizedGL: unrealizedGL,
      afterTaxYieldRoc: afterTaxYieldRoc,
      totalReturnBeforeTax: totalReturnBeforeTax,
      totalReturnAfterTax: totalReturnAfterTax,
      distributions: descDist,
      priceBars: sortedCloses,
      qualifies: true,
    );
  }

  /// Index of the latest bar whose date is on or before [divDate].
  /// Returns -1 if [bars] is empty or every bar starts after [divDate].
  @visibleForTesting
  static int barIndexAt(DateTime divDate, List<PriceBar> bars) {
    if (bars.isEmpty) return -1;
    int idx = -1;
    for (int i = 0; i < bars.length; i++) {
      if (!bars[i].date.isAfter(divDate)) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// Close of the bar identified by [barIndexAt], walking backwards if that
  /// bar's close is null. If the date is before all bars, falls back to the
  /// first available bar's close. Returns null only when no bar in the entire
  /// list has a non-null close.
  @visibleForTesting
  static double? priceAt(DateTime divDate, List<PriceBar> bars) {
    if (bars.isEmpty) return null;
    final idx = barIndexAt(divDate, bars);
    final start = idx >= 0 ? idx : 0;
    for (int j = start; j >= 0; j--) {
      final v = bars[j].close;
      if (v != null) return v;
    }
    for (int j = start + 1; j < bars.length; j++) {
      final v = bars[j].close;
      if (v != null) return v;
    }
    return null;
  }
}

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
      distributionList.add(
        DistributionEntry(
          date: DateTime.fromMillisecondsSinceEpoch(divTs * 1000, isUtc: true),
          amount: amt,
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
  );
}

class YieldScreen extends StatefulWidget {
  /// Optional HTTP client seam. Production leaves this null and a one-shot
  /// client is created per request; tests inject a mock to drive the
  /// Calculate → parse → render flow without real network access.
  final http.Client? client;

  const YieldScreen({super.key, this.client});

  @override
  State<YieldScreen> createState() => _YieldScreenState();
}

class _YieldScreenState extends State<YieldScreen> {
  final _tickerCtrl = TextEditingController();
  final _federalCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _localCtrl = TextEditingController(text: '0');
  final _rocCtrl = TextEditingController(text: '71');
  final _scrollCtrl = ScrollController();

  bool _loading = false;
  String? _error;
  YieldResult? _result;

  static const _kTicker = 'last_ticker';
  static const _kFederal = 'rate_federal';
  static const _kState = 'rate_state';
  static const _kLocal = 'rate_local';
  static const _kRoc = 'rate_roc';

  @override
  void initState() {
    super.initState();
    _loadSavedInputs();
  }

  Future<void> _loadSavedInputs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _tickerCtrl.text = prefs.getString(_kTicker) ?? '';
      _federalCtrl.text = prefs.getString(_kFederal) ?? '';
      _stateCtrl.text = prefs.getString(_kState) ?? '';
      _localCtrl.text = prefs.getString(_kLocal) ?? '0';
      _rocCtrl.text = prefs.getString(_kRoc) ?? '71';
    });
  }

  Future<void> _saveInputs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTicker, _tickerCtrl.text.trim().toUpperCase());
    await prefs.setString(_kFederal, _federalCtrl.text);
    await prefs.setString(_kState, _stateCtrl.text);
    await prefs.setString(_kLocal, _localCtrl.text);
    await prefs.setString(_kRoc, _rocCtrl.text);
  }

  @override
  void dispose() {
    _tickerCtrl.dispose();
    _federalCtrl.dispose();
    _stateCtrl.dispose();
    _localCtrl.dispose();
    _rocCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // Select the field's entire contents so the next keystroke replaces them.
  // Matches the desktop "click to type-over" pattern users expect on numeric
  // and ticker fields. Posting to the next frame lets the framework finish
  // its own focus/selection bookkeeping before we override.
  void _selectAll(TextEditingController c) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.text.isEmpty) return;
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
  }

  Future<void> _calculate() async {
    // Dismiss the keyboard the moment the user commits — otherwise it
    // covers the result card on smaller phones.
    FocusManager.instance.primaryFocus?.unfocus();
    final ticker = _tickerCtrl.text.trim().toUpperCase();
    if (ticker.isEmpty) {
      setState(() => _error = 'Enter a ticker.');
      return;
    }
    final fed = double.tryParse(_federalCtrl.text.trim());
    final state = double.tryParse(_stateCtrl.text.trim());
    final localText = _localCtrl.text.trim();
    final local = double.tryParse(localText.isEmpty ? '0' : localText);
    final rocText = _rocCtrl.text.trim();
    final roc = double.tryParse(rocText.isEmpty ? '0' : rocText);
    if (fed == null || state == null || local == null) {
      setState(() => _error = 'Tax rates must be numeric (e.g. 32 for 32%).');
      return;
    }
    if (roc == null || roc < 0 || roc > 100) {
      setState(() => _error = 'Return of capital % must be between 0 and 100.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });

    await _saveInputs();

    try {
      final result = await _fetchYield(
        ticker: ticker,
        federalPct: fed,
        statePct: state,
        localPct: local,
        rocPct: roc,
      );
      setState(() {
        _result = result;
        _loading = false;
      });
      // Slide the inputs up so the full result card (through the reference
      // grid) is in view without the user scrolling.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
        );
      });
    } catch (e) {
      setState(() {
        _error = 'Lookup failed: $e';
        _loading = false;
      });
    }
  }

  Future<YieldResult> _fetchYield({
    required String ticker,
    required double federalPct,
    required double statePct,
    required double localPct,
    required double rocPct,
  }) async {
    final uri = Uri.parse(
      '$yahooBase/v8/finance/chart/$ticker?interval=1d&range=1y&events=div',
    );
    final client = widget.client ?? http.Client();
    try {
      final resp = await client.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
        },
      );
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      return parseYahooChart(
        resp.body,
        ticker: ticker,
        federalPct: federalPct,
        statePct: statePct,
        localPct: localPct,
        rocPct: rocPct,
      );
    } finally {
      // Only dispose clients we created; never close an injected one.
      if (widget.client == null) client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('TrueYield'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Calculate'),
              Tab(text: 'Distributions'),
              Tab(text: 'Prices'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildCalculateTab(context),
              _DistributionsTab(result: _result),
              _PricesTab(result: _result),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalculateTab(BuildContext context) {
    const fieldDecoration = InputDecoration(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    );
    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _tickerCtrl,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Ticker',
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  onTap: () => _selectAll(_tickerCtrl),
                  inputFormatters: [
                    TextInputFormatter.withFunction((oldVal, newVal) {
                      return newVal.copyWith(text: newVal.text.toUpperCase());
                    }),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _rocCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Return of capital %',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_rocCtrl),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _federalCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(labelText: 'Federal %'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_federalCtrl),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _stateCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(labelText: 'State %'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_stateCtrl),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _localCtrl,
                  style: const TextStyle(fontSize: 18),
                  decoration: fieldDecoration.copyWith(labelText: 'Local %'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_localCtrl),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _loading ? null : _calculate,
              child: _loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text(
                      'Calculate',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              margin: EdgeInsets.zero,
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!),
              ),
            ),
          if (_result != null) _ResultCard(result: _result!),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final YieldResult result;
  const _ResultCard({required this.result});

  String _money(double v) => '\$${v.toStringAsFixed(2)}';
  String _signedMoney(double v) =>
      '${v < 0 ? '−' : '+'}\$${v.abs().toStringAsFixed(2)}';
  String _signedPct(double v) =>
      '${v < 0 ? '−' : '+'}${(v.abs() * 100).toStringAsFixed(1)}%';
  String _pctPlain(double v) => '${(v * 100).toStringAsFixed(1)}%';

  static final Color _gain = Colors.greenAccent.shade400;
  static final Color _loss = Colors.redAccent.shade200;
  Color _signColor(double v) => v < 0 ? _loss : _gain;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);

    if (!r.qualifies) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(r.ticker, style: theme.textTheme.headlineSmall),
                  _StatusChip(qualifies: false),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Current price'),
                  Text(
                    _money(r.currentPrice),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Does not qualify (${r.reason})',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final afterTaxValue = r.nav - r.taxThisYear;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The entered ticker is highlighted in the input field above and the
            // current price shows in the yield lines + reference grid, so the
            // header is just the headline TTM distributions figure.
            _StmtRow(
              label: 'TTM distributions',
              sub: 'reinvested via DRIP',
              value: _money(r.sumDistributions),
              headline: true,
            ),
            const Divider(height: 28),

            // ─── BLUF: total return after tax, with the three components that
            //     sum to it nested beneath (income + unrealized G/L − tax).
            _StmtRow(
              label: 'Total return after tax',
              sub:
                  '${_money(r.startPrice)} → ${_money(afterTaxValue)} on your start',
              value: _signedPct(r.totalReturnAfterTax),
              valueColor: _signColor(r.totalReturnAfterTax),
              headline: true,
            ),
            const SizedBox(height: 8),
            // DRIP benefit memo — not a summed component (it's already baked
            // into Income + Unrealized G/L), so it shows share growth, not $.
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                'DRIP grew your shares 1.00 → '
                '${r.dripShares.toStringAsFixed(2)} '
                '(+${(r.compoundedGrossYield * 100).toStringAsFixed(0)}%)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _StmtRow(
              label: 'Income (taxable)',
              sub:
                  '${_money(r.sumDistributions)} × '
                  '${(100 - r.rocPct).toStringAsFixed(0)}% (1−ROC)',
              value: _signedMoney(r.incomeAmount),
              valueColor: _gain,
              nested: true,
            ),
            _StmtRow(
              label: 'Unrealized G/L',
              sub: '${_money(r.nav)} value − ${_money(r.costBasis)} basis',
              value: _signedMoney(r.unrealizedGL),
              valueColor: _signColor(r.unrealizedGL),
              nested: true,
            ),
            _StmtRow(
              label: 'Tax this year',
              sub:
                  '${(r.combinedRate * 100).toStringAsFixed(0)}% on the '
                  '${_money(r.incomeAmount)} income',
              value: _signedMoney(-r.taxThisYear),
              valueColor: _loss,
              nested: true,
            ),
            const Divider(height: 28),

            // ─── The two yields (denominator = current price), kept separate
            //     from the cost-based total return above.
            _StmtRow(
              label: 'Advertised yield',
              sub: '${_money(r.sumDistributions)} ÷ ${_money(r.currentPrice)}',
              value: _pctPlain(r.grossYield),
            ),
            const SizedBox(height: 8),
            _StmtRow(
              label: 'After-tax yield',
              sub:
                  'kept ${_money(r.sumDistributions - r.taxThisYear)} ÷ '
                  '${_money(r.currentPrice)}',
              value: _pctPlain(r.afterTaxYieldRoc),
            ),
            const Divider(height: 28),

            _ReferenceGrid(result: r),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool qualifies;
  const _StatusChip({required this.qualifies});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOk = qualifies;
    final bg = isOk
        ? Colors.green.withValues(alpha: 0.18)
        : scheme.errorContainer;
    final fg = isOk ? Colors.greenAccent.shade400 : scheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isOk ? 'Qualifies' : 'Does not qualify',
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

// One line of the result statement: a label (+ optional explanatory sub) on the
// left and a right-aligned value. `headline` renders the BLUF total return big;
// `nested` indents the components that sum to it.
class _StmtRow extends StatelessWidget {
  final String label;
  final String? sub;
  final String value;
  final Color? valueColor;
  final bool headline;
  final bool nested;
  const _StmtRow({
    required this.label,
    this.sub,
    required this.value,
    this.valueColor,
    this.headline = false,
    this.nested = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = headline
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.titleSmall?.copyWith(
            fontWeight: nested ? FontWeight.w500 : FontWeight.w600,
          );
    final valueStyle =
        (headline
                ? theme.textTheme.headlineMedium
                : theme.textTheme.titleMedium)
            ?.copyWith(
              color: valueColor ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
    return Padding(
      padding: EdgeInsets.only(
        left: nested ? 16 : 0,
        top: nested ? 3 : 0,
        bottom: nested ? 3 : 0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: labelStyle),
                if (sub != null)
                  Text(
                    sub!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: valueStyle),
        ],
      ),
    );
  }
}

// "Show your work" grid: the raw Price/Shares/NAV/Cost-basis/Unrealized-G/L the
// statement above is computed from, across the start (~1y ago) and current month.
class _ReferenceGrid extends StatelessWidget {
  final YieldResult result;
  const _ReferenceGrid({required this.result});

  String _money(double v) => '\$${v.toStringAsFixed(2)}';
  String _signedMoney(double v) =>
      '${v < 0 ? '−' : '+'}\$${v.abs().toStringAsFixed(2)}';

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String _monthLabel(DateTime d) =>
      "${_months[d.month - 1]} '${(d.year % 100).toString().padLeft(2, '0')}";

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    final bars = r.priceBars;
    final startLabel = bars.isNotEmpty ? _monthLabel(bars.first.date) : 'Start';
    final endLabel = bars.isNotEmpty ? _monthLabel(bars.last.date) : 'Now';

    final headStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = theme.textTheme.bodyMedium;
    final numStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    TableRow row(String label, String start, String end, {Color? endColor}) {
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(label, style: labelStyle),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
            child: Text(start, textAlign: TextAlign.right, style: numStyle),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(
              end,
              textAlign: TextAlign.right,
              style: numStyle?.copyWith(color: endColor),
            ),
          ),
        ],
      );
    }

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: IntrinsicColumnWidth(),
        2: IntrinsicColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                startLabel,
                textAlign: TextAlign.right,
                style: headStyle,
              ),
            ),
            Text(endLabel, textAlign: TextAlign.right, style: headStyle),
          ],
        ),
        row('Price', _money(r.startPrice), _money(r.currentPrice)),
        row('Shares', '1.00', r.dripShares.toStringAsFixed(2)),
        row(
          'Present Value (price × shares)',
          _money(r.startPrice),
          _money(r.nav),
        ),
        row('Cost basis', _money(r.startPrice), _money(r.costBasis)),
        row(
          'Unrealized G/L',
          '—',
          _signedMoney(r.unrealizedGL),
          endColor: r.unrealizedGL < 0
              ? Colors.redAccent.shade200
              : Colors.greenAccent.shade400,
        ),
      ],
    );
  }
}

String _fmtDate(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

class _DistributionsTab extends StatelessWidget {
  final YieldResult? result;
  const _DistributionsTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Run Calculate to populate.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (r.distributions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${r.ticker}: no distributions in the last 12 months.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final total = r.sumDistributions;
    final theme = Theme.of(context);
    final firstDate = r.distributions.last.date;
    final lastDate = r.distributions.first.date;
    final avg = total / r.distributions.length;
    final rocAmount = total - r.incomeAmount;
    final rocInt = r.rocPct.round();
    final incInt = (100 - r.rocPct).round();
    final splitHeadStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final splitNumStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: r.distributions.length + 3,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${r.distributions.length} distributions • '
                  '${_fmtDate(firstDate)} → ${_fmtDate(lastDate)}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Total \$${total.toStringAsFixed(4)} • '
                  'avg \$${avg.toStringAsFixed(4)}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(2),
                    1: IntrinsicColumnWidth(),
                    2: IntrinsicColumnWidth(),
                  },
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    TableRow(
                      children: [
                        const SizedBox(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'Return of cap. ($rocInt%)',
                            textAlign: TextAlign.right,
                            style: splitHeadStyle,
                          ),
                        ),
                        Text(
                          'Income ($incInt%)',
                          textAlign: TextAlign.right,
                          style: splitHeadStyle,
                        ),
                      ],
                    ),
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Amount',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 10,
                          ),
                          child: Text(
                            '\$${rocAmount.toStringAsFixed(2)}',
                            textAlign: TextAlign.right,
                            style: splitNumStyle,
                          ),
                        ),
                        Text(
                          '\$${r.incomeAmount.toStringAsFixed(2)}',
                          textAlign: TextAlign.right,
                          style: splitNumStyle,
                        ),
                      ],
                    ),
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Taxed now?',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 10,
                          ),
                          child: Text(
                            'No',
                            textAlign: TextAlign.right,
                            style: splitNumStyle,
                          ),
                        ),
                        Text(
                          'Yes (\$${r.taxThisYear.toStringAsFixed(2)})',
                          textAlign: TextAlign.right,
                          style: splitNumStyle,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Date',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Amount',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }
        if (i == r.distributions.length + 2) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total (12mo)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '\$${total.toStringAsFixed(4)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }
        final d = r.distributions[i - 2];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmtDate(d.date)),
              Text('\$${d.amount.toStringAsFixed(4)}'),
            ],
          ),
        );
      },
    );
  }
}

class _PricesTab extends StatelessWidget {
  final YieldResult? result;
  const _PricesTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Run Calculate to populate.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final closes = [...r.priceBars]..sort((a, b) => b.date.compareTo(a.date));
    if (closes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No daily closes returned.', textAlign: TextAlign.center),
        ),
      );
    }
    final theme = Theme.of(context);
    final valid = closes.map((c) => c.close).whereType<double>().toList();
    final mean = valid.isEmpty
        ? 0
        : valid.reduce((a, b) => a + b) / valid.length;
    final hi = valid.isEmpty ? 0 : valid.reduce((a, b) => a > b ? a : b);
    final lo = valid.isEmpty ? 0 : valid.reduce((a, b) => a < b ? a : b);
    final last = closes.first.date;
    final first = closes.last.date;
    final pctChange = (valid.length >= 2)
        ? (valid.first - valid.last) / valid.last * 100
        : 0;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: closes.length + 2,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${closes.length} daily closes • '
                  '${_fmtDate(first)} → ${_fmtDate(last)}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Current \$${r.currentPrice.toStringAsFixed(2)} • '
                  'mean \$${mean.toStringAsFixed(2)} • '
                  'range \$${lo.toStringAsFixed(2)}–\$${hi.toStringAsFixed(2)} • '
                  '12mo Δ ${pctChange >= 0 ? '+' : ''}'
                  '${pctChange.toStringAsFixed(2)}%',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Date',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Close',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }
        final c = closes[i - 2];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmtDate(c.date)),
              Text(c.close == null ? '—' : '\$${c.close!.toStringAsFixed(2)}'),
            ],
          ),
        );
      },
    );
  }
}
