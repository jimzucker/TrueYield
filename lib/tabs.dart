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

// Lots tab: full per-lot detail — one card per purchase (open or closed) with
// its dates, prices, shares, cost, distributions, income, tax, G/L, and return.
class _LotsTab extends StatelessWidget {
  final YieldResult? result;
  const _LotsTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
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
    if (!r.qualifies) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${r.ticker}: ${r.reason ?? 'does not qualify'}.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (r.isDefaultLot) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No lots entered — the result uses the default 1-share view. Add '
            'lots on the Calculate tab to track real positions here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final afterTaxValue = r.nav - r.taxThisYear;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Text(r.ticker, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '${r.lots.length} lots · ${_money(r.totalCost)} cost → '
          '${_money(r.nav)} value',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        _StmtRow(
          label: 'Total return after tax',
          sub: '${_money(r.totalCost)} → ${_money(afterTaxValue)} on your cost',
          value: _signedPct(r.totalReturnAfterTax),
          valueColor: signColor(theme, r.totalReturnAfterTax),
          headline: true,
        ),
        const SizedBox(height: 8),
        for (final l in r.lots)
          _LotDetailCard(lot: l, currentPrice: r.currentPrice),
      ],
    );
  }
}

class _LotDetailCard extends StatelessWidget {
  final LotResult lot;
  final double currentPrice;
  const _LotDetailCard({required this.lot, required this.currentPrice});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = lot;
    final growthPct = (l.sharesGrowth * 100);

    // A compact stat block (muted label over a bold tabular value) — two per
    // row so the card reads as a table and fills the width instead of one tall
    // column of label-left / value-right rows.
    Widget stat(String k, String v, {Color? color}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          k,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          v,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    final cells = <Widget>[
      stat('Bought', '${fmtDateHuman(l.buyDate)} @ ${_money(l.buyPrice)}'),
      stat(
        l.isClosed ? 'Sold' : 'Held',
        l.isClosed
            ? '${fmtDateHuman(l.sellDate!)} @ ${_money(l.sellPrice!)} · '
                  '${l.isLongTerm ? 'long-term' : 'short-term'}'
            : 'to today @ ${_money(currentPrice)}',
      ),
      stat(
        'Shares (DRIP)',
        '${fmtShares(l.initialShares)} → ${fmtShares(l.finalShares)} '
            '(+${growthPct.toStringAsFixed(growthPct < 10 ? 1 : 0)}%)',
      ),
      stat('Principal (cost)', _money(l.cost)),
      stat('Distributions', _money(l.distributions)),
      stat(
        'Income (taxable)',
        _signedMoney(l.incomeAmount),
        color: gainColor(theme),
      ),
      stat(l.isClosed ? 'Value at sale' : 'Value now', _money(l.nav)),
      stat('Income tax', _signedMoney(-l.taxThisYear), color: lossColor(theme)),
      stat(
        l.isClosed ? 'Realized G/L' : 'Unrealized G/L',
        _signedMoney(l.gl),
        color: signColor(theme, l.gl),
      ),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${fmtShares(l.initialShares)} sh · bought '
                    '${fmtDateHuman(l.buyDate)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: l.isClosed
                        ? theme.colorScheme.tertiaryContainer
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    l.isClosed ? 'Sold' : 'Open',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: l.isClosed
                          ? theme.colorScheme.onTertiaryContainer
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 18),
            for (var i = 0; i < cells.length; i += 2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cells[i]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: i + 1 < cells.length
                          ? cells[i + 1]
                          : const SizedBox(),
                    ),
                  ],
                ),
              ),
            const Divider(height: 18),
            stat(
              'Total return (after tax)',
              _signedPct(l.totalReturnAfterTax),
              color: signColor(theme, l.totalReturnAfterTax),
            ),
          ],
        ),
      ),
    );
  }
}

// Diagnostics tab: runs the lot math on deterministic synthetic data across a
// range of holding periods so anyone can sanity-check it without a network call.
class _DiagnosticsTab extends StatelessWidget {
  const _DiagnosticsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scenarios = buildDiagnostics(DateTime.now());
    final passed = scenarios.where((s) => s.pass).length;
    final allPass = passed == scenarios.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Diagnostics', style: theme.textTheme.headlineSmall),
            ),
            _PassPill(ok: allPass, text: '$passed / ${scenarios.length} pass'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Self-test scenarios on round synthetic data — price steps \$10 → \$15 '
          '→ \$20 over ~3 years (mirrored for the falling case), a \$0.10 monthly '
          'distribution, 30% tax, 50% ROC. Each card checks the computed numbers '
          'against expected values baked in from those inputs (no network).',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final s in scenarios) _DiagnosticCard(scenario: s),
      ],
    );
  }
}

class _DiagnosticCard extends StatelessWidget {
  final DiagnosticScenario scenario;
  const _DiagnosticCard({required this.scenario});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = scenario.result;
    final initial = r.totalInitialShares;
    final tag = r.isDefaultLot
        ? 'Default'
        : '${r.lots.length} lot${r.lots.length == 1 ? '' : 's'}';

    Widget row(String k, String v, {Color? c}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            k,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            v,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: c,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    final tagPill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        tag,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    // Collapsible: passing scenarios stay tucked away so only FAILs (auto-open)
    // demand attention on this self-test tab.
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: !scenario.pass,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  scenario.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // The headline after-tax return, visible while collapsed so each
              // scenario shows its result at a glance.
              Text(
                _signedPct(r.totalReturnAfterTax),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: signColor(theme, r.totalReturnAfterTax),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              if (scenario.checks.isNotEmpty) ...[
                _PassPill(
                  ok: scenario.pass,
                  text: scenario.pass ? 'PASS' : 'FAIL',
                ),
                const SizedBox(width: 6),
              ],
              tagPill,
            ],
          ),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          children: [
            Text(
              scenario.detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 18),
            row(
              'Total return after tax',
              _signedPct(r.totalReturnAfterTax),
              c: signColor(theme, r.totalReturnAfterTax),
            ),
            row('Cost → value', '${_money(r.totalCost)} → ${_money(r.nav)}'),
            row(
              'Shares',
              '${_grouped(initial.toStringAsFixed(2))} → '
                  '${_grouped(r.dripShares.toStringAsFixed(2))}',
            ),
            row('Distributions received', _money(r.distributionsReceived)),
            // Income/Tax are always +/−, so no decorative color — reserve color
            // for the signed G/L and total-return rows where it carries meaning.
            row('Income (taxable)', _signedMoney(r.incomeAmount)),
            if (r.realizedGL != 0)
              row(
                'Realized G/L',
                _signedMoney(r.realizedGL),
                c: signColor(theme, r.realizedGL),
              ),
            row(
              'Unrealized G/L',
              _signedMoney(r.unrealizedGL),
              c: signColor(theme, r.unrealizedGL),
            ),
            row('Income tax', _signedMoney(-r.taxThisYear)),
            if (r.capGainsTax != 0)
              row('Capital-gains tax', _signedMoney(-r.capGainsTax)),
            if (scenario.checks.isNotEmpty) ...[
              const Divider(height: 18),
              Text(
                'Expected vs actual',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              for (final c in scenario.checks) _checkRow(theme, c),
            ],
          ],
        ),
      ),
    );
  }

  // One "expected vs actual ✓/✗" line. Money-ish magnitudes (≥10) print as
  // dollars; small ones (shares, %) keep two decimals.
  Widget _checkRow(ThemeData theme, DiagCheck c) {
    String fmt(double v) => v.abs() >= 10 ? _money(v) : v.toStringAsFixed(2);
    final color = c.ok ? gainColor(theme) : lossColor(theme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(
            c.ok ? Icons.check_circle : Icons.cancel,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              c.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            c.ok ? fmt(c.actual) : '${fmt(c.actual)} ≠ ${fmt(c.expected)}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: c.ok ? null : lossColor(theme),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// A small rounded pass/fail (or summary) pill used on the Diagnostics tab.
class _PassPill extends StatelessWidget {
  final bool ok;
  final String text;
  const _PassPill({required this.ok, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = ok
        ? gainColor(theme).withValues(alpha: 0.18)
        : theme.colorScheme.errorContainer;
    final fg = ok ? gainColor(theme) : theme.colorScheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// Info tab: a short user guide — what the app tells you, how to use it, and how
// to read each result line — plus disclaimers and About/links.
/// Raw-GitHub base for the committed history CSVs (kept current on main by the
/// daily refresh workflow).
const String _dataBase =
    'https://raw.githubusercontent.com/jimzucker/TrueYield/main/data';

class _InfoTab extends StatelessWidget {
  const _InfoTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final section = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final rocFunds = kRocByTickerByEpoch.length;
    final rocPoints = kRocByTickerByEpoch.values.fold<int>(
      0,
      (sum, m) => sum + m.length,
    );
    final rocTickers = kRocByTickerByEpoch.keys.toList()..sort();
    final rocEpochs = kRocByTickerByEpoch.values.expand((m) => m.keys);
    final rocSinceYear = rocEpochs.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            rocEpochs.reduce((a, b) => a < b ? a : b) * 1000,
            isUtc: true,
          ).year;
    final priceSinceYear = kPriceEarliest.isEmpty
        ? null
        : int.tryParse(kPriceEarliest.split('-').first);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('TrueYield', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Know what a dividend stock or ETF actually pays you — after taxes, '
            'and after the share price moves.',
            style: TextStyle(color: muted),
          ),
          const Divider(height: 28),
          Text('How to use', style: section),
          const SizedBox(height: 6),
          const Text(
            '1.  Enter a ticker (e.g. YMAG, SCHD, JEPI).\n'
            '2.  Return of capital % — the portion of distributions not taxed '
            'this year. For many YieldMax funds it auto-fills from their recent '
            'Section 19a-1 notices when you type the ticker; otherwise it '
            'defaults to 71. Edit it anytime (tap “reset” to restore the '
            'fund’s value).\n'
            '3.  Enter your marginal tax rates — federal, state, local — plus a '
            'long-term gains % (federal; defaults to 15). Short-term gains use '
            'your ordinary rate; long-term gains use the LT % (both add State + '
            'Local).\n'
            '4.  (Optional) Add lots — real buy dates with a share count and/or '
            'cost (enter both and that’s your exact basis). Give a lot a sell '
            'date and it books a realized gain (taxed long-term if held over a '
            'year); leave it blank to hold to today. No lots = one share bought '
            'a year ago.\n'
            '5.  Tap Calculate.',
          ),
          const Divider(height: 12),
          const _InfoSection(
            title: 'Reading the result',
            children: [
              _InfoTerm(
                term: 'Total return after tax',
                desc:
                    'The bottom line — what one share bought a year ago is worth '
                    'now, net of this year’s tax: income and price change together.',
              ),
              _InfoTerm(
                term: 'DRIP grew your shares',
                desc:
                    'Distributions are reinvested (a broker DRIP), compounding '
                    'your share count — e.g. 1.00 → 1.59.',
              ),
              _InfoTerm(
                term: 'Income / G/L / Income tax / Capital-gains tax',
                desc:
                    'The pieces that sum to the total: taxable income, the gain '
                    'or loss on your shares, the income tax due now, and — when '
                    'you’ve sold lots — capital-gains tax on the realized gain '
                    '(short-term at your ordinary rate, long-term at the lower '
                    'long-term rate).',
              ),
              _InfoTerm(
                term: 'Advertised vs After-tax yield',
                desc:
                    'The headline distribution yield vs what you actually keep '
                    'after tax — both measured on today’s price.',
              ),
              _InfoTerm(
                term: 'Reference grid',
                desc:
                    'The raw Price, Shares, Present Value, and Cost basis the '
                    'math is built from — a year ago vs now.',
              ),
            ],
          ),
          const _InfoSection(
            title: 'The other tabs',
            children: [
              Text(
                '•  Distributions — every payout in the last 12 months, split '
                'into return of capital vs taxable income.\n'
                '•  Prices — the daily closes behind the calculation.',
              ),
            ],
          ),
          const Divider(height: 12),
          Text('Bundled ROC data', style: section),
          const SizedBox(height: 6),
          Text(
            'Return-of-capital history parsed from issuers’ Section 19a-1 '
            'notices and built into the app:',
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _RocStat(value: '$rocFunds', label: 'funds'),
              _RocStat(value: '$rocPoints', label: 'distributions'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'ROC notices back to ${rocSinceYear ?? '—'}. Daily prices for '
            '$kPriceFundCount funds (${_grouped('$kPriceCloseCount')} closes) '
            'back to ${priceSinceYear ?? '—'}.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 4),
          Text(
            'Updated ${fmtDateHuman(DateTime.parse(kRocHistoryAsOf))} · '
            'download links live at the bottom of the Distributions and '
            'Prices tabs.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 10),
          Text(
            'Tracked funds ($rocFunds) — any other ticker still works, just '
            'without bundled ROC:',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in rocTickers)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    t,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 12),
          const _InfoSection(
            title: 'Disclaimers',
            children: [
              Text(
                '•  Not investment advice — figures are historical (trailing 12 '
                'months), not a forecast.\n'
                '•  US tax model: one combined marginal rate on the taxable '
                '(non-ROC) portion of distributions (income tax). A sold lot’s '
                'realized gain is also taxed — short-term (held ≤ 1 yr) at that '
                'ordinary rate, long-term at your Long-term gains rate; realized '
                'losses offset gains. State/Local apply to both.\n'
                '•  Return of capital % is your assumption — set it from the '
                'fund’s latest Section 19a notice.\n'
                '•  Data is Yahoo Finance’s public, unofficial endpoint and can '
                'change without notice.',
              ),
            ],
          ),
          const Divider(height: 12),
          Text('Links', style: section),
          const SizedBox(height: 6),
          Wrap(
            spacing: 18,
            runSpacing: 2,
            children: [
              const _AboutLink(
                label: 'Project & README',
                url: 'https://github.com/jimzucker/TrueYield#readme',
              ),
              const _AboutLink(
                label: 'License (Apache 2.0)',
                url: 'https://github.com/jimzucker/TrueYield/blob/main/LICENSE',
              ),
              const _AboutLink(
                label: 'Privacy policy',
                url:
                    'https://github.com/jimzucker/TrueYield/blob/main/PRIVACY.md',
              ),
              _AboutLink(
                icon: Icons.article_outlined,
                label: 'Open-source licenses',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'TrueYield',
                  applicationLegalese: '© 2026 James A. Zucker · Apache-2.0',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '© 2026 James A. Zucker · Apache-2.0\n'
            'Not affiliated with Yahoo. Yahoo and Yahoo Finance are trademarks of '
            'their respective owners.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
      ),
    );
  }
}

/// An always-visible Info-tab section: a bold header followed by its content
/// (no collapsing — the guide is short enough to read top to bottom).
class _InfoSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _InfoSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _InfoTerm extends StatelessWidget {
  final String term;
  final String desc;
  const _InfoTerm({required this.term, required this.desc});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            term,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One compact figure in the Info-tab "Bundled ROC data" row.
class _RocStat extends StatelessWidget {
  final String value;
  final String label;
  const _RocStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutLink extends StatelessWidget {
  final String label;
  final String? url;
  final VoidCallback? onTap;
  final IconData icon;
  const _AboutLink({
    required this.label,
    this.url,
    this.onTap,
    this.icon = Icons.open_in_new,
  });

  Future<void> _launch() async {
    final u = url;
    if (u == null) return;
    try {
      await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort: ignore if no handler can open the link.
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap ?? _launch,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A "Download (CSV)" footer for a data tab — links to the committed,
/// raw-GitHub-hosted history files (kept current on main by the daily workflow).
class _ExportFooter extends StatelessWidget {
  final List<({String label, String url})> files;
  const _ExportFooter({required this.files});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Download (CSV)',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          for (final f in files)
            _AboutLink(
              icon: Icons.download_outlined,
              label: f.label,
              url: f.url,
            ),
        ],
      ),
    );
  }
}

class _DistributionsTab extends StatelessWidget {
  final YieldResult? result;
  // Per-distribution ROC editing. [rocOverrides] are keyed by div epoch
  // (seconds); a row with no override shows [defaultRoc]. [onRocChanged] sets
  // (or clears, with null) an override and recomputes the result in place.
  final Map<int, double> rocOverrides;
  // Bundled per-payable-date ROC% history for this ticker (keyed by payable
  // epoch), auto-filled per row when no user override exists.
  final Map<int, double>? rocHistory;
  // Settled full-year ROC% by year (8937 actual / 19a aggregate); used for rows
  // in a completed calendar year (year < [currentYear]).
  final Map<int, double>? rocAnnual;
  final int currentYear;
  final double defaultRoc;
  final void Function(int epoch, double? pct) onRocChanged;
  const _DistributionsTab({
    required this.result,
    this.rocOverrides = const {},
    this.rocHistory,
    this.rocAnnual,
    this.currentYear = 0,
    this.defaultRoc = 0,
    this.onRocChanged = _noop,
  });

  static void _noop(int epoch, double? pct) {}

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
    // Per-share figures — the ROC split is a per-share concept independent of
    // the lots. With per-distribution ROC the effective rate is a blend.
    final taxableIncome = r.perShareIncome;
    final rocAmount = total - taxableIncome;
    final taxThisYear = r.perShareIncome * r.combinedRate;
    final rocInt = total > 0 ? (rocAmount / total * 100).round() : 0;
    final incInt = 100 - rocInt;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: r.distributions.length + 4,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == r.distributions.length + 3) {
          return const _ExportFooter(
            files: [
              (
                label: 'Return-of-capital history (all funds)',
                url: '$_dataBase/roc_history.csv',
              ),
              (
                label: 'Distributions history (all funds)',
                url: '$_dataBase/distributions_history.csv',
              ),
            ],
          );
        }
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${r.distributions.length} payouts · '
                  '${_fmtMonthYear(firstDate)} – ${_fmtMonthYear(lastDate)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                _StatGrid([
                  (
                    label: 'Total distributions',
                    value: _money(total),
                    color: null,
                  ),
                  (
                    label: 'Average per payout',
                    value: _money(avg),
                    color: null,
                  ),
                  (
                    label: 'Return of capital ($rocInt%)',
                    value: _money(rocAmount),
                    color: null,
                  ),
                  (
                    label: 'Taxable income ($incInt%)',
                    value: _money(taxableIncome),
                    color: null,
                  ),
                  (
                    label: 'Income tax',
                    value: _signedMoney(-taxThisYear),
                    color: lossColor(theme),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  'Each row’s ROC % auto-fills from the fund’s Section 19a-1 '
                  'notice when available, else the $rocInt% default. Tap any row '
                  'to override it; clear it to revert.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        if (i == 1) {
          final headStyle = theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          );
          return Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(flex: 5, child: Text('Date', style: headStyle)),
                Expanded(
                  flex: 3,
                  child: Text(
                    'Amount',
                    textAlign: TextAlign.right,
                    style: headStyle,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'ROC %',
                    textAlign: TextAlign.right,
                    style: headStyle,
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
                  _money(total),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          );
        }
        final d = r.distributions[i - 2];
        final epoch = d.date.toUtc().millisecondsSinceEpoch ~/ 1000;
        // Completed year → the settled full-year figure; current year → the
        // live per-distribution notice value.
        final histRoc =
            rocAnnualFor(rocAnnual, d.date.year, currentYear) ??
            rocFromHistory(rocHistory, epoch);
        final rocPct = rocOverrides[epoch] ?? histRoc ?? defaultRoc;
        final rocDollars = d.amount * rocPct / 100;
        final num = theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(fmtDateHuman(d.date), style: num),
                    ),
                    Text(
                      'ROC ${_money4(rocDollars)} · taxable '
                      '${_money4(d.amount - rocDollars)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _money4(d.amount),
                    textAlign: TextAlign.right,
                    style: num,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: _RocCell(
                  overrideRoc: rocOverrides[epoch],
                  historyRoc: histRoc,
                  defaultRoc: defaultRoc,
                  onChanged: (pct) => onRocChanged(epoch, pct),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// One tap-to-edit ROC-% cell for a distribution row. Renders as plain right-
// aligned text (an override stands out in the primary color; the inherited
// default is muted) and only becomes a text field while being edited. Commits
// on submit/focus-loss; an empty value clears the override (reverts to default).
class _RocCell extends StatefulWidget {
  final double? overrideRoc;
  // Auto-filled from the bundled 19a-1 history when present and not overridden.
  final double? historyRoc;
  final double defaultRoc;
  final ValueChanged<double?> onChanged;
  const _RocCell({
    required this.overrideRoc,
    this.historyRoc,
    required this.defaultRoc,
    required this.onChanged,
  });

  @override
  State<_RocCell> createState() => _RocCellState();
}

class _RocCellState extends State<_RocCell> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.overrideRoc == null ? '' : fmtNum(widget.overrideRoc!),
    );
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && _editing) {
      _commit();
      setState(() => _editing = false);
    }
  }

  void _startEditing() {
    _ctrl.text = widget.overrideRoc == null ? '' : fmtNum(widget.overrideRoc!);
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  void _commit() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) {
      widget.onChanged(null);
      return;
    }
    final v = double.tryParse(t);
    if (v != null && v >= 0 && v <= 100) widget.onChanged(v);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_editing) {
      return TextField(
        controller: _ctrl,
        focusNode: _focus,
        autofocus: true,
        textAlign: TextAlign.right,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          border: OutlineInputBorder(),
          suffixText: '%',
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onSubmitted: (_) {
          _commit();
          setState(() => _editing = false);
        },
      );
    }
    // Three states: user override (primary, bold) > 19a-1 history (normal
    // onSurface) > the global default assumption (muted).
    final hasOverride = widget.overrideRoc != null;
    final hasHistory = !hasOverride && widget.historyRoc != null;
    final value = widget.overrideRoc ?? widget.historyRoc ?? widget.defaultRoc;
    final color = hasOverride
        ? theme.colorScheme.primary
        : hasHistory
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: _startEditing,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${fmtNum(value)}%',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color,
              fontWeight: hasOverride ? FontWeight.w700 : FontWeight.w400,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
              decorationColor: theme.colorScheme.outline,
            ),
          ),
        ),
      ),
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
        ? 0.0
        : valid.reduce((a, b) => a + b) / valid.length;
    final hi = valid.isEmpty ? 0.0 : valid.reduce((a, b) => a > b ? a : b);
    final lo = valid.isEmpty ? 0.0 : valid.reduce((a, b) => a < b ? a : b);
    final last = closes.first.date;
    final first = closes.last.date;
    final pctChange = (valid.length >= 2)
        ? (valid.first - valid.last) / valid.last * 100
        : 0.0;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: closes.length + 3,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == closes.length + 2) {
          return const _ExportFooter(
            files: [
              (
                label: 'Daily prices history (all funds)',
                url: '$_dataBase/prices_history.csv',
              ),
            ],
          );
        }
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${closes.length} daily closes · '
                  '${_fmtMonthYear(first)} – ${_fmtMonthYear(last)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                _StatGrid([
                  (
                    label: 'Current price',
                    value: _money(r.currentPrice),
                    color: null,
                  ),
                  (
                    label: '12-month change',
                    value: _signedPct(pctChange / 100),
                    color: signColor(theme, pctChange),
                  ),
                  (label: 'Average close', value: _money(mean), color: null),
                  (
                    label: 'Range',
                    value: '${_money(lo)} – ${_money(hi)}',
                    color: null,
                  ),
                ]),
                const SizedBox(height: 14),
                _PriceSparkline(result: r),
              ],
            ),
          );
        }
        if (i == 1) {
          final head = theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurfaceVariant,
          );
          return Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(flex: 5, child: Text('Date', style: head)),
                Expanded(
                  flex: 4,
                  child: Text(
                    'Change',
                    textAlign: TextAlign.right,
                    style: head,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text('Close', textAlign: TextAlign.right, style: head),
                ),
              ],
            ),
          );
        }
        final c = closes[i - 2];
        // closes is newest-first, so closes[i-1] is the prior trading day.
        final prior = (i - 1) < closes.length ? closes[i - 1].close : null;
        final delta = (c.close != null && prior != null)
            ? c.close! - prior
            : null;
        final num = theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(flex: 5, child: Text(fmtDateHuman(c.date), style: num)),
              Expanded(
                flex: 4,
                child: Text(
                  delta == null ? '' : _signedMoney(delta),
                  textAlign: TextAlign.right,
                  style: num?.copyWith(
                    color: delta == null ? null : signColor(theme, delta),
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  c.close == null ? '—' : _money(c.close!),
                  textAlign: TextAlign.right,
                  style: num,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
