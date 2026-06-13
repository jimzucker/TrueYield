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

class YieldScreen extends StatefulWidget {
  /// Optional HTTP client seam. Production leaves this null and a one-shot
  /// client is created per request; tests inject a mock to drive the
  /// Calculate → parse → render flow without real network access.
  final http.Client? client;

  const YieldScreen({super.key, this.client});

  @override
  State<YieldScreen> createState() => _YieldScreenState();
}

class _YieldScreenState extends State<YieldScreen> with WidgetsBindingObserver {
  final _tickerCtrl = TextEditingController(text: 'YMAG');
  final _tickerFocus = FocusNode();
  // Default marginal rates (a common high-tax-state profile); editable and
  // remembered across tickers once the user changes them.
  final _federalCtrl = TextEditingController(text: '24');
  final _stateCtrl = TextEditingController(text: '6.85');
  final _localCtrl = TextEditingController(text: '3.876');
  final _ltGainsCtrl = TextEditingController(text: '15');
  final _rocCtrl = TextEditingController(text: '56.7');
  final _scrollCtrl = ScrollController();

  bool _loading = false;
  String? _error;
  YieldResult? _result;
  // When the shown result was fetched (device clock). Drives the "As of" stamp
  // and the stale-on-a-new-day check; null whenever no result is displayed.
  DateTime? _resultFetchedAt;

  // Purchases for the CURRENT ticker. Empty = the single default lot (1 share,
  // ~1 year ago), preserving the original behavior. Lots are saved per ticker
  // (see _lotsByTicker) and swapped when the ticker changes.
  List<Lot> _lots = [];
  // Per-distribution ROC % overrides for the current ticker, keyed by the Yahoo
  // dividend epoch (seconds). Survives re-fetch because the key is stable.
  Map<int, double> _rocOverrides = {};

  // Saved lots / ROC overrides per ticker, so each fund keeps its own positions.
  // _lotsTicker is the ticker _lots/_rocOverrides currently belong to.
  Map<String, List<Lot>> _lotsByTicker = {};
  Map<String, Map<int, double>> _rocByTicker = {};
  String _lotsTicker = '';

  // The ticker whose bundled ROC we last auto-filled into the ROC field, so we
  // only re-apply when the ticker actually changes to a different known fund.
  String? _rocSourceTicker;

  // Price bars from the last successful fetch, plus the ticker they're for, so a
  // new/edited lot can default its cost to the close on the buy date.
  List<PriceBar> _lastBars = const [];
  String _lastBarsTicker = '';

  static const _kTicker = 'last_ticker';
  static const _kFederal = 'rate_federal';
  static const _kState = 'rate_state';
  static const _kLocal = 'rate_local';
  static const _kLtGains = 'rate_lt_gains';
  static const _kRoc = 'rate_roc';
  static const _kLotsByTicker = 'lots_by_ticker';
  static const _kRocByTicker = 'roc_overrides_by_ticker';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedInputs();
    for (final c in [
      _tickerCtrl,
      _federalCtrl,
      _stateCtrl,
      _localCtrl,
      _ltGainsCtrl,
      _rocCtrl,
    ]) {
      c.addListener(_clearStaleResult);
    }
    // Entering a known YieldMax ticker auto-fills its ROC % from the bundled
    // 19a-1 data; the ticker/ROC fields also drive the source caption, so keep
    // the form repainting as they change.
    _tickerCtrl.addListener(_maybeAutofillRoc);
    _tickerCtrl.addListener(_rebuildForCaption);
    _rocCtrl.addListener(_rebuildForCaption);
    // When the ticker field loses focus, load that ticker's saved lots (or
    // clear to the default), keeping each fund's positions separate.
    _tickerFocus.addListener(() {
      if (!_tickerFocus.hasFocus) {
        _syncLotsForTicker();
        _prefetchForLots();
      }
    });
  }

  void _rebuildForCaption() {
    if (mounted) setState(() {});
  }

  // When the ticker changes to a known fund, set the ROC % field to that fund's
  // trailing return-of-capital. Only fires on a genuine ticker change, so a
  // user's manual ROC edit isn't clobbered while they keep the same ticker.
  void _maybeAutofillRoc() {
    final tkr = _tickerCtrl.text.trim().toUpperCase();
    if (tkr == _rocSourceTicker) return;
    final roc = rocForTicker(tkr);
    if (roc == null) {
      _rocSourceTicker = null;
      return;
    }
    _rocSourceTicker = tkr;
    _rocCtrl.text = fmtNum(roc);
  }

  // If the app is resumed on a later calendar day, the shown result's TTM
  // window has shifted, so silently re-run against the same inputs to refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _result != null &&
        !_loading &&
        _resultFetchedAt != null &&
        isStale(_resultFetchedAt!, DateTime.now())) {
      _calculate();
    }
  }

  // Editing any input invalidates a shown result, so drop it — the card must
  // only ever display numbers that match the current inputs.
  void _clearStaleResult() {
    if (_result != null || _error != null) {
      setState(() {
        _result = null;
        _error = null;
        _resultFetchedAt = null;
      });
    }
  }

  Future<void> _loadSavedInputs() async {
    final prefs = await SharedPreferences.getInstance();
    // Corrupt JSON must never crash boot — fall back to the defaults.
    Map<String, List<Lot>> lotsByTicker = {};
    Map<String, Map<int, double>> rocByTicker = {};
    try {
      final raw = prefs.getString(_kLotsByTicker);
      if (raw != null) {
        lotsByTicker = (json.decode(raw) as Map<String, dynamic>).map(
          (t, v) => MapEntry(t, [
            for (final e in v as List) Lot.fromJson(e as Map<String, dynamic>),
          ]),
        );
      }
    } catch (_) {
      lotsByTicker = {};
    }
    try {
      final raw = prefs.getString(_kRocByTicker);
      if (raw != null) {
        rocByTicker = (json.decode(raw) as Map<String, dynamic>).map(
          (t, v) => MapEntry(
            t,
            (v as Map<String, dynamic>).map(
              (k, pct) => MapEntry(int.parse(k), (pct as num).toDouble()),
            ),
          ),
        );
      }
    } catch (_) {
      rocByTicker = {};
    }
    final ticker = (prefs.getString(_kTicker) ?? 'YMAG').trim().toUpperCase();
    setState(() {
      _tickerCtrl.text = prefs.getString(_kTicker) ?? 'YMAG';
      _federalCtrl.text = prefs.getString(_kFederal) ?? '24';
      _stateCtrl.text = prefs.getString(_kState) ?? '6.85';
      _localCtrl.text = prefs.getString(_kLocal) ?? '3.876';
      _ltGainsCtrl.text = prefs.getString(_kLtGains) ?? '15';
      _rocCtrl.text = prefs.getString(_kRoc) ?? '56.7';
      _lotsByTicker = lotsByTicker;
      _rocByTicker = rocByTicker;
      _lotsTicker = ticker;
      _lots = List.of(lotsByTicker[ticker] ?? const <Lot>[]);
      _rocOverrides = Map.of(rocByTicker[ticker] ?? const <int, double>{});
    });
  }

  // Fold the current ticker's in-memory lots / ROC overrides into the per-ticker
  // maps (dropping the entry when empty) so they persist and survive a swap.
  void _flushLotsToMap() {
    final t = _lotsTicker.isNotEmpty
        ? _lotsTicker
        : _tickerCtrl.text.trim().toUpperCase();
    if (t.isEmpty) return;
    if (_lots.isEmpty) {
      _lotsByTicker.remove(t);
    } else {
      _lotsByTicker[t] = List.of(_lots);
    }
    if (_rocOverrides.isEmpty) {
      _rocByTicker.remove(t);
    } else {
      _rocByTicker[t] = Map.of(_rocOverrides);
    }
  }

  // Load the entered ticker's saved lots (or clear to the default) when the
  // ticker changes — each fund keeps its own positions.
  void _syncLotsForTicker() {
    final t = _tickerCtrl.text.trim().toUpperCase();
    if (t == _lotsTicker) return;
    _flushLotsToMap(); // saves under the old ticker
    setState(() {
      _lots = List.of(_lotsByTicker[t] ?? const <Lot>[]);
      _rocOverrides = Map.of(_rocByTicker[t] ?? const <int, double>{});
      _lotsTicker = t;
      _result = null;
      _error = null;
      _resultFetchedAt = null;
    });
    _saveInputs();
  }

  Future<void> _saveInputs() async {
    _flushLotsToMap();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTicker, _tickerCtrl.text.trim().toUpperCase());
    await prefs.setString(_kFederal, _federalCtrl.text);
    await prefs.setString(_kState, _stateCtrl.text);
    await prefs.setString(_kLocal, _localCtrl.text);
    await prefs.setString(_kLtGains, _ltGainsCtrl.text);
    await prefs.setString(_kRoc, _rocCtrl.text);
    await prefs.setString(
      _kLotsByTicker,
      json.encode(
        _lotsByTicker.map(
          (t, ls) => MapEntry(t, [for (final l in ls) l.toJson()]),
        ),
      ),
    );
    await prefs.setString(
      _kRocByTicker,
      json.encode(
        _rocByTicker.map(
          (t, m) => MapEntry(t, m.map((k, v) => MapEntry(k.toString(), v))),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickerCtrl.dispose();
    _tickerFocus.dispose();
    _federalCtrl.dispose();
    _stateCtrl.dispose();
    _localCtrl.dispose();
    _ltGainsCtrl.dispose();
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

  // One right-aligned, tabular numeric tax-rate field. Wrapped in Expanded so it
  // drops straight into the 2×2 rate grid.
  Widget _rateField(
    TextEditingController c,
    String label,
    InputDecoration deco,
  ) {
    return Expanded(
      child: TextField(
        controller: c,
        textAlign: TextAlign.right,
        style: const TextStyle(
          fontSize: 18,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        decoration: deco.copyWith(labelText: label, suffixText: '%'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onTap: () => _selectAll(c),
      ),
    );
  }

  // null when no explicit lots → compute() uses the single default lot.
  List<Lot>? _activeLots() => _lots.isEmpty ? null : _lots;

  // Tickers the user has saved data for (lots and/or ROC overrides), plus the
  // current field — sorted, for the recent-ticker pick list.
  List<String> _storedTickers() {
    final set = <String>{..._lotsByTicker.keys, ..._rocByTicker.keys};
    final cur = _tickerCtrl.text.trim().toUpperCase();
    if (cur.isNotEmpty) set.add(cur);
    final list = set.where((t) => t.isNotEmpty).toList()..sort();
    return list;
  }

  // Pick a stored ticker: drop it in the field (its lots load via the listeners)
  // and run the calculation so the result shows immediately.
  void _pickStoredTicker(String t) {
    _tickerCtrl.text = t;
    _syncLotsForTicker();
    _calculate();
  }

  // Closing price on [date] from the last fetch, but only when it's for the
  // ticker currently in the field (so we never apply a stale fund's price).
  // null when we have no matching data yet — the cost is then derived from the
  // market price at calculate time instead.
  double? _closeOn(DateTime date) {
    if (_lastBars.isEmpty) return null;
    if (_lastBarsTicker != _tickerCtrl.text.trim().toUpperCase()) return null;
    return YieldMath.priceAt(date, _lastBars);
  }

  // The most recent close DAY (last bar's date) when we have data for the
  // current ticker, else the last weekday. Used as a new lot's default buy date.
  DateTime _lastCloseDay() {
    final t = _tickerCtrl.text.trim().toUpperCase();
    if (_lastBars.isNotEmpty && _lastBarsTicker == t) {
      final d = _lastBars.last.date;
      return DateTime.utc(d.year, d.month, d.day);
    }
    return lastTradingDay(DateTime.now());
  }

  // Background fetch when a ticker is committed, so new/edited lots can default
  // their price to the last close even before the user taps Calculate. Silent:
  // it only populates the price bars; it never shows a result or an error.
  Future<void> _prefetchForLots() async {
    final ticker = _tickerCtrl.text.trim().toUpperCase();
    if (ticker.isEmpty) return;
    if (_lastBarsTicker == ticker && _lastBars.isNotEmpty) return;
    try {
      final result = await _fetchYield(
        ticker: ticker,
        federalPct: 0,
        statePct: 0,
        localPct: 0,
        rocPct: 0,
        ltGainsPct: 0,
      );
      if (!mounted || result.priceBars.isEmpty) return;
      setState(() {
        _lastBars = result.priceBars;
        _lastBarsTicker = ticker;
      });
    } catch (_) {
      // Background prefetch — ignore failures (bad ticker, offline, etc.).
    }
  }

  // Yahoo dividend epoch (seconds) — the stable key for a ROC override.
  int _epochOf(DateTime d) => d.toUtc().millisecondsSinceEpoch ~/ 1000;

  // Mutate the lots and persist. A lot change can require a wider fetch range
  // (an older buy date needs more history), so the shown card is dropped — the
  // user re-taps Calculate, which refetches with the right range.
  void _mutateLots(void Function() change) {
    setState(() {
      change();
      // Bind the lots to the ticker currently in the field, so a later ticker
      // change flushes them under the right fund.
      _lotsTicker = _tickerCtrl.text.trim().toUpperCase();
      _result = null;
      _error = null;
      _resultFetchedAt = null;
    });
    _saveInputs();
  }

  // Set or clear a per-distribution ROC override. Unlike a lot change, this
  // needs no new data, so the shown result recomputes in place (live).
  void _setRocOverride(int epoch, double? pct) {
    setState(() {
      if (pct == null) {
        _rocOverrides.remove(epoch);
      } else {
        _rocOverrides[epoch] = pct;
      }
      _recomputeInPlace();
    });
    _saveInputs();
  }

  // Re-run the pure math on the already-fetched bars/distributions with the
  // current lots, tax rates, and ROC overrides — no network. Caller wraps this
  // in setState. No-op until a qualifying result exists.
  // Parse the tax/ROC fields. Non-numeric entries return null (so [_calculate]
  // can validate); empty Local/ROC count as 0.
  ({double? fed, double? state, double? local, double? lt, double? roc})
  _parseRates() {
    final localText = _localCtrl.text.trim();
    final ltText = _ltGainsCtrl.text.trim();
    final rocText = _rocCtrl.text.trim();
    return (
      fed: double.tryParse(_federalCtrl.text.trim()),
      state: double.tryParse(_stateCtrl.text.trim()),
      local: double.tryParse(localText.isEmpty ? '0' : localText),
      lt: double.tryParse(ltText.isEmpty ? '0' : ltText),
      roc: double.tryParse(rocText.isEmpty ? '0' : rocText),
    );
  }

  void _recomputeInPlace() {
    final r = _result;
    if (r == null || !r.qualifies) return;
    final (:fed, :state, :local, :lt, :roc) = _parseRates();
    _result = YieldMath.compute(
      ticker: r.ticker,
      currentPrice: r.currentPrice,
      federalPct: fed ?? 0,
      statePct: state ?? 0,
      localPct: local ?? 0,
      distributions: [
        for (final d in r.distributions)
          DistributionEntry(
            date: d.date,
            amount: d.amount,
            rocPct:
                _rocOverrides[_epochOf(d.date)] ??
                rocAnnualFor(
                  rocAnnualForTicker(r.ticker),
                  d.date.year,
                  DateTime.now().year,
                ) ??
                rocFromHistory(rocHistoryForTicker(r.ticker), _epochOf(d.date)),
          ),
      ],
      priceBars: r.priceBars,
      rocPct: roc ?? 0,
      ltGainsPct: lt ?? 0,
      lots: _activeLots(),
    );
  }

  Future<void> _calculate() async {
    // Dismiss the keyboard the moment the user commits — otherwise it
    // covers the result card on smaller phones.
    FocusManager.instance.primaryFocus?.unfocus();
    // Make sure _lots match the entered ticker before we compute.
    _syncLotsForTicker();
    final ticker = _tickerCtrl.text.trim().toUpperCase();
    if (ticker.isEmpty) {
      setState(() => _error = 'Enter a ticker.');
      return;
    }
    final (:fed, :state, :local, :lt, :roc) = _parseRates();
    if (fed == null || state == null || local == null || lt == null) {
      setState(() => _error = 'Tax rates must be numeric (e.g. 32 for 32%).');
      return;
    }
    if (roc == null || roc < 0 || roc > 100) {
      setState(() => _error = 'Return of capital % must be between 0 and 100.');
      return;
    }
    if (lt < 0 || lt > 100) {
      setState(() => _error = 'Long-term gains % must be between 0 and 100.');
      return;
    }
    final now = DateTime.now();
    for (final lot in _lots) {
      if (lot.shares == null || lot.shares! <= 0) {
        setState(() => _error = 'Each lot needs a positive quantity.');
        return;
      }
      if (lot.price != null && lot.price! <= 0) {
        setState(() => _error = 'Lot price must be positive.');
        return;
      }
      if (lot.buyDate.isAfter(now)) {
        setState(() => _error = 'A lot buy date cannot be in the future.');
        return;
      }
      final sell = lot.sellDate;
      if (sell != null) {
        if (sell.isAfter(now)) {
          setState(() => _error = 'A lot sell date cannot be in the future.');
          return;
        }
        if (sell.isBefore(lot.buyDate)) {
          setState(
            () => _error = 'A lot sell date must be after its buy date.',
          );
          return;
        }
      }
    }

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _resultFetchedAt = null;
    });

    await _saveInputs();

    try {
      final result = await _fetchYield(
        ticker: ticker,
        federalPct: fed,
        statePct: state,
        localPct: local,
        rocPct: roc,
        ltGainsPct: lt,
      );
      setState(() {
        _result = result;
        _resultFetchedAt = DateTime.now();
        _lastBars = result.priceBars;
        _lastBarsTicker = result.ticker;
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
        _error = friendlyFetchError(e, ticker);
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
    required double ltGainsPct,
  }) async {
    // Fetch enough history to cover the earliest lot; no lots → the default
    // 1-year window (the original behavior).
    final now = DateTime.now();
    final earliestBuy = _lots.isEmpty
        ? now.subtract(const Duration(days: 365))
        : _lots.map((l) => l.buyDate).reduce((a, b) => a.isBefore(b) ? a : b);
    final range = yahooRangeFor(earliestBuy, now);
    final uri = Uri.parse(
      '$yahooBase/v8/finance/chart/$ticker?interval=1d&range=$range&events=div',
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
        ltGainsPct: ltGainsPct,
        rocByDivEpoch: _rocOverrides,
        rocHistory: rocHistoryForTicker(ticker),
        rocAnnual: rocAnnualForTicker(ticker),
        currentYear: DateTime.now().year,
        lots: _activeLots(),
      );
    } finally {
      // Only dispose clients we created; never close an injected one.
      if (widget.client == null) client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('TrueYield'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              Tab(text: 'Calculate'),
              Tab(text: 'Lots'),
              Tab(text: 'Distributions'),
              Tab(text: 'Prices'),
              Tab(text: 'Info'),
              Tab(text: 'Diag'),
            ],
          ),
        ),
        // Cap the content width and center it so the form/cards don't stretch
        // edge-to-edge on a wide desktop/web window (mobile is unaffected).
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: TabBarView(
                children: [
                  _buildCalculateTab(context),
                  _LotsTab(result: _result),
                  _DistributionsTab(
                    result: _result,
                    rocOverrides: _rocOverrides,
                    rocHistory: rocHistoryForTicker(_result?.ticker ?? ''),
                    rocAnnual: rocAnnualForTicker(_result?.ticker ?? ''),
                    currentYear: DateTime.now().year,
                    defaultRoc: double.tryParse(_rocCtrl.text.trim()) ?? 0,
                    onRocChanged: _setRocOverride,
                  ),
                  _PricesTab(result: _result),
                  const _InfoTab(),
                  const _DiagnosticsTab(),
                ],
              ),
            ),
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
    final theme = Theme.of(context);
    final stored = _storedTickers();
    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Taxes first: one global set, applied to every ticker (not
          //     stored per ticker). Income-tax rates + the long-term capital-
          //     gains rate in a 2×2. ST gains use Fed+State+Local; LT gains use
          //     LT%+State+Local (see YieldMath.compute).
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2),
            child: Text(
              'Tax rates',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // All four on one row when there's room (wide/web), else a 2×2 grid so
          // the labels don't clip on a phone.
          LayoutBuilder(
            builder: (context, constraints) {
              final fed = _rateField(_federalCtrl, 'Federal', fieldDecoration);
              final st = _rateField(_stateCtrl, 'State', fieldDecoration);
              final loc = _rateField(_localCtrl, 'Local', fieldDecoration);
              final lt = _rateField(_ltGainsCtrl, 'LT gains', fieldDecoration);
              const gap = SizedBox(width: 10);
              if (constraints.maxWidth >= 600) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [fed, gap, st, gap, loc, gap, lt],
                );
              }
              return Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [fed, gap, st],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [loc, gap, lt],
                  ),
                ],
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Divider(height: 1),
          ),
          // ─── Per-ticker: the symbol and its return-of-capital assumption.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _tickerCtrl,
                  focusNode: _tickerFocus,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Ticker',
                    filled: true,
                    fillColor: theme.colorScheme.primaryContainer,
                    suffixIcon: stored.isEmpty
                        ? null
                        : PopupMenuButton<String>(
                            icon: Icon(
                              Icons.arrow_drop_down,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                            tooltip: 'Saved tickers',
                            onSelected: _pickStoredTicker,
                            itemBuilder: (_) => [
                              for (final t in stored)
                                PopupMenuItem(value: t, child: Text(t)),
                            ],
                          ),
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
                child: TextField(
                  controller: _rocCtrl,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 18,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Return of capital',
                    suffixText: '%',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onTap: () => _selectAll(_rocCtrl),
                ),
              ),
            ],
          ),
          _buildRocSourceCaption(context),
          const SizedBox(height: 16),
          _buildLotsSection(context),
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
          if (_result != null)
            _ResultCard(result: _result!, fetchedAt: _resultFetchedAt),
        ],
      ),
    );
  }

  // Caption under the ROC field for a recognized YieldMax fund: shows the
  // bundled 19a-1 source when the field matches, or a one-tap reset when the
  // user has overridden it. Nothing for unknown tickers.
  Widget _buildRocSourceCaption(BuildContext context) {
    final tkr = _tickerCtrl.text.trim().toUpperCase();
    final roc = rocForTicker(tkr);
    if (roc == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final current = double.tryParse(_rocCtrl.text.trim());
    final matches = current != null && (current - roc).abs() < 0.05;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: matches
          ? Text(
              'ROC auto-filled from $tkr’s 19a-1 notices '
              '(${fmtNum(roc)}%, as of $kRocDataAsOf).',
              style: muted,
            )
          : InkWell(
              onTap: () {
                _rocSourceTicker = tkr;
                _rocCtrl.text = fmtNum(roc);
              },
              child: Text.rich(
                TextSpan(
                  style: muted,
                  children: [
                    TextSpan(text: '$tkr’s 19a-1 ROC is ${fmtNum(roc)}% — '),
                    TextSpan(
                      text: 'reset',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // Lots editor: a card listing each purchase (buy date + size). Empty = the
  // implicit default lot (1 share, ~1 year ago), so the original single-share
  // flow needs no setup. Adding lots turns the result into a portfolio.
  Widget _buildLotsSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Lots',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _mutateLots(() {
                    // Default: 100 shares bought on the last close day, priced at
                    // that day's close (when we have prices for the ticker).
                    final buyDate = _lastCloseDay();
                    _lots.add(
                      Lot(
                        buyDate: buyDate,
                        shares: 100,
                        price: _closeOn(buyDate),
                      ),
                    );
                  }),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add lot'),
                ),
              ],
            ),
            if (_lots.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  'Default: 1 share held ~1 year (the TTM view). Tap “Add lot” '
                  'to use your real shares — each new lot starts at 100 shares '
                  'bought today, ready to edit.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (int i = 0; i < _lots.length; i++)
                _LotRow(
                  key: ValueKey(i),
                  index: i + 1,
                  lot: _lots[i],
                  closeOn: _closeOn,
                  defaultPrice: _closeOn(_lots[i].buyDate),
                  onChanged: (l) => _mutateLots(() => _lots[i] = l),
                  onRemove: () => _mutateLots(() => _lots.removeAt(i)),
                ),
          ],
        ),
      ),
    );
  }
}

// One editable purchase row: buy date plus optional shares and cost fields.
// Owns its field controllers (seeded once in initState) so parent rebuilds on
// each keystroke don't fight the user's cursor. [closeOn] returns the close on a
// date when prices are available, so changing the buy date refreshes the cost.
class _LotRow extends StatefulWidget {
  final int index;
  final Lot lot;
  final double? Function(DateTime) closeOn;
  // The close on the lot's buy date (when known), used to pre-fill the Price
  // field for a lot whose price hasn't been set yet.
  final double? defaultPrice;
  final ValueChanged<Lot> onChanged;
  final VoidCallback onRemove;
  const _LotRow({
    super.key,
    required this.index,
    required this.lot,
    required this.closeOn,
    required this.defaultPrice,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_LotRow> createState() => _LotRowState();
}

class _LotRowState extends State<_LotRow> {
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _priceCtrl;
  late final FocusNode _qtyFocus;
  late final FocusNode _priceFocus;

  // The price to show in the field: the entered price, else the buy-date close.
  String get _priceFieldText => widget.lot.price != null
      ? fmtMoneyField(widget.lot.price!)
      : (widget.defaultPrice != null
            ? fmtMoneyField(widget.defaultPrice!)
            : '');

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: fmtNum(widget.lot.shares));
    _priceCtrl = TextEditingController(text: _priceFieldText);
    _qtyFocus = FocusNode();
    _priceFocus = FocusNode();
  }

  // Rows are keyed by index, so removing a middle lot reuses this State for a
  // different lot. When that happens (and we're not mid-edit), resync the field
  // — but never disturb the user's active typing. The Price field also refills
  // when the buy-date close arrives from a background fetch (defaultPrice).
  @override
  void didUpdateWidget(_LotRow old) {
    super.didUpdateWidget(old);
    if (!_qtyFocus.hasFocus && widget.lot.shares != old.lot.shares) {
      final t = fmtNum(widget.lot.shares);
      if (_qtyCtrl.text != t) _qtyCtrl.text = t;
    }
    if (!_priceFocus.hasFocus &&
        (widget.lot.price != old.lot.price ||
            widget.defaultPrice != old.defaultPrice)) {
      final t = _priceFieldText;
      if (_priceCtrl.text != t) _priceCtrl.text = t;
    }
  }

  @override
  void dispose() {
    _qtyFocus.dispose();
    _priceFocus.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  // Emit an edit. `keepSell: false` clears the sale; otherwise sellDate is
  // preserved (and dropped only if a new buy date lands after it).
  void _emit({
    DateTime? buyDate,
    double? shares,
    double? price,
    bool sharesSet = false,
    bool priceSet = false,
    DateTime? sellDate,
    bool keepSell = true,
  }) {
    final lot = widget.lot;
    final newBuy = buyDate ?? lot.buyDate;
    DateTime? sell = sellDate ?? (keepSell ? lot.sellDate : null);
    if (sell != null && sell.isBefore(newBuy)) sell = null;
    widget.onChanged(
      Lot(
        buyDate: newBuy,
        shares: sharesSet ? shares : lot.shares,
        price: priceSet ? price : lot.price,
        sellDate: sell,
      ),
    );
  }

  Future<void> _pickBuyDate() async {
    final now = DateTime.now();
    final initial = widget.lot.buyDate.isAfter(now) ? now : widget.lot.buyDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (picked == null) return;
    final buyDate = DateTime.utc(picked.year, picked.month, picked.day);
    // Default the price to that day's close when we have prices, so the basis
    // tracks the market unless the user overrides it.
    final close = widget.closeOn(buyDate);
    if (close != null) {
      final price = (close * 100).roundToDouble() / 100;
      _priceCtrl.text = fmtMoneyField(price);
      _emit(buyDate: buyDate, price: price, priceSet: true);
    } else {
      _emit(buyDate: buyDate);
    }
  }

  Future<void> _pickSellDate() async {
    final lot = widget.lot;
    final now = DateTime.now();
    final initial = lot.sellDate ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(lot.buyDate) ? lot.buyDate : initial,
      firstDate: lot.buyDate,
      lastDate: now,
    );
    if (picked == null) return;
    _emit(sellDate: DateTime.utc(picked.year, picked.month, picked.day));
  }

  void _clearSell() => _emit(keepSell: false);

  Widget _dateButton(String label, VoidCallback onTap, {bool muted = false}) {
    final theme = Theme.of(context);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        visualDensity: VisualDensity.compact,
        foregroundColor: muted ? theme.colorScheme.onSurfaceVariant : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.event, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _numField(
    TextEditingController ctrl,
    FocusNode focus,
    String label, {
    String? prefix,
    required void Function(double?) onValue,
  }) {
    return TextField(
      controller: ctrl,
      focusNode: focus,
      textAlign: TextAlign.right,
      style: const TextStyle(
        fontSize: 14,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        prefixText: prefix,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (t) {
        final s = t.trim();
        onValue(s.isEmpty ? null : double.tryParse(s));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final lot = widget.lot;
    final theme = Theme.of(context);
    // Effective price (entered, else the buy-date close if we have it) → the
    // computed principal that recalcs live as qty / price change.
    final effPrice = lot.price ?? widget.defaultPrice;
    final principal = (lot.shares != null && effPrice != null)
        ? lot.shares! * effPrice
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: which lot, its status, and remove.
            Row(
              children: [
                Text(
                  'Lot ${widget.index}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: lot.isClosed
                        ? theme.colorScheme.tertiaryContainer
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    lot.isClosed ? 'Sold' : 'Open',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: lot.isClosed
                          ? theme.colorScheme.onTertiaryContainer
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: widget.onRemove,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove lot',
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Buy and (optional) sell dates.
            Row(
              children: [
                Expanded(
                  child: _dateButton(
                    'Buy ${fmtDateHuman(lot.buyDate)}',
                    _pickBuyDate,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _dateButton(
                    lot.isClosed
                        ? 'Sell ${fmtDateHuman(lot.sellDate!)}'
                        : 'Add sell date',
                    _pickSellDate,
                    muted: !lot.isClosed,
                  ),
                ),
                if (lot.isClosed)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: _clearSell,
                    icon: const Icon(Icons.undo, size: 16),
                    tooltip: 'Clear sell date (hold)',
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // Qty × Price = Principal (principal is computed, read-only).
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 3,
                  child: _numField(
                    _qtyCtrl,
                    _qtyFocus,
                    'Shares',
                    onValue: (v) => _emit(shares: v, sharesSet: true),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('×'),
                ),
                Expanded(
                  flex: 4,
                  child: _numField(
                    _priceCtrl,
                    _priceFocus,
                    'Price',
                    prefix: '\$',
                    onValue: (v) => _emit(price: v, priceSet: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Cost basis',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        principal == null ? 'at close' : _money(principal),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
