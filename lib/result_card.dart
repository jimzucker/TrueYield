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

class _ResultCard extends StatelessWidget {
  final YieldResult result;
  final DateTime? fetchedAt;
  const _ResultCard({required this.result, this.fetchedAt});

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
                  Text(r.ticker, style: theme.textTheme.titleLarge),
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
    // No lots entered → the original "1 share a year ago" per-share/TTM view.
    // With real lots → a by-lot, dollar-denominated portfolio view.
    final defaultView = r.isDefaultLot;
    final lotCount = r.lots.length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(r.ticker, style: theme.textTheme.titleLarge),
                _StatusChip(qualifies: true),
              ],
            ),
            const SizedBox(height: 6),
            if (fetchedAt != null) ...[
              Text(
                'As of ${fmtStamp(fetchedAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
            ],
            // Header: per-share TTM total for the default hypothetical; the
            // actual dollars received (and reinvested) for a real portfolio.
            _StmtRow(
              label: defaultView
                  ? 'TTM distributions'
                  : 'Distributions received',
              sub: 'reinvested via DRIP',
              value: _money(
                defaultView ? r.sumDistributions : r.distributionsReceived,
              ),
              headline: true,
            ),
            const Divider(height: 28),

            // ─── BLUF: total return after tax, with the three components that
            //     sum to it nested beneath (income + G/L − tax).
            _StmtRow(
              label: 'Total return after tax',
              sub: defaultView
                  ? '${_money(r.startPrice)} → ${_money(afterTaxValue)} on your start'
                  : '${_money(r.totalCost)} → ${_money(afterTaxValue)} on your cost',
              value: _signedPct(r.totalReturnAfterTax),
              valueColor: signColor(theme, r.totalReturnAfterTax),
              headline: true,
            ),
            const SizedBox(height: 8),
            // DRIP benefit memo — not a summed component (it's already baked
            // into Income + G/L), so it shows share growth, not $.
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                defaultView
                    ? 'DRIP grew your shares 1.00 → '
                          '${fmtShares(r.dripShares)} '
                          '(+${(r.compoundedGrossYield * 100).toStringAsFixed(0)}%)'
                    : 'DRIP grew your shares ${fmtShares(r.totalInitialShares)} → '
                          '${fmtShares(r.dripShares)} '
                          'across $lotCount ${lotCount == 1 ? 'lot' : 'lots'} '
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
              sub: defaultView
                  ? '${_money(r.sumDistributions)} × '
                        '${(100 - r.rocPct).toStringAsFixed(0)}% (1−ROC)'
                  : 'taxable part of ${_money(r.distributionsReceived)} received',
              value: _signedMoney(r.incomeAmount),
              valueColor: gainColor(theme),
              nested: true,
            ),
            if (r.realizedGL != 0)
              _StmtRow(
                label: 'Realized G/L',
                sub: 'booked at sale · before capital-gains tax',
                value: _signedMoney(r.realizedGL),
                valueColor: signColor(theme, r.realizedGL),
                nested: true,
              ),
            if (r.unrealizedGL != 0 || r.realizedGL == 0)
              _StmtRow(
                label: 'Unrealized G/L',
                sub: r.realizedGL != 0
                    ? 'paper gain on lots still held'
                    : '${_money(r.nav)} value − ${_money(r.costBasis)} basis',
                value: _signedMoney(r.unrealizedGL),
                valueColor: signColor(theme, r.unrealizedGL),
                nested: true,
              ),
            _StmtRow(
              label: 'Income tax',
              sub:
                  '${(r.combinedRate * 100).toStringAsFixed(0)}% on the '
                  '${_money(r.incomeAmount)} income',
              value: _signedMoney(-r.taxThisYear),
              valueColor: lossColor(theme),
              nested: true,
            ),
            if (r.capGainsTax != 0)
              _StmtRow(
                label: 'Capital-gains tax',
                sub:
                    'on realized gains (short-term at your rate, long-term lower)',
                value: _signedMoney(-r.capGainsTax),
                valueColor: lossColor(theme),
                nested: true,
              ),
            const Divider(height: 28),

            // The per-share yields (denominator = current price) are a
            // single-share TTM concept — only meaningful for the default view.
            if (defaultView) ...[
              _StmtRow(
                label: 'Advertised yield',
                sub:
                    '${_money(r.sumDistributions)} ÷ ${_money(r.currentPrice)}',
                value: _pctPlain(r.grossYield),
              ),
              const SizedBox(height: 8),
              _StmtRow(
                label: 'After-tax yield',
                sub:
                    'kept ${_money(r.sumDistributions - r.perShareIncome * r.combinedRate)} ÷ '
                    '${_money(r.currentPrice)}',
                value: _pctPlain(r.afterTaxYieldRoc),
              ),
              const Divider(height: 28),
            ],

            // Cost vs after-tax value: how much the position grew, what share
            // came from income vs price, and the tax taken off the top.
            _ReturnBars(result: r),
            const Divider(height: 28),

            if (defaultView)
              _ReferenceGrid(result: r)
            else
              _PortfolioGrid(result: r),
          ],
        ),
      ),
    );
  }
}

/// One contribution row of the return chart: a signed dollar amount that adds
/// to (or subtracts from) the net return. [isNet] is the summary total.
class ReturnContribution {
  final String label;
  final double value; // signed dollars
  final bool isNet;
  const ReturnContribution(this.label, this.value, {this.isNet = false});
}

/// The signed pieces of the after-tax return — income, gain/loss, and taxes —
/// plus the net total. The non-net values sum to the net (= after-tax value −
/// cost), so the diverging bars read as "what built the return, what took from
/// it." Pure + testable. Mirrors the statement's component rows.
List<ReturnContribution> returnContributions(YieldResult r) {
  return [
    ReturnContribution('Income', r.incomeAmount),
    if (r.realizedGL != 0) ReturnContribution('Realized G/L', r.realizedGL),
    if (r.unrealizedGL != 0 || r.realizedGL == 0)
      ReturnContribution('Unrealized G/L', r.unrealizedGL),
    ReturnContribution('Income tax', -r.taxThisYear),
    if (r.capGainsTax != 0)
      ReturnContribution('Capital-gains tax', -r.capGainsTax),
    ReturnContribution(
      'Net return',
      r.nav - r.taxThisYear - r.capGainsTax - r.totalCost,
      isNet: true,
    ),
  ];
}

/// Horizontal diverging bars: each return component gets its own full-width row
/// (positive right, negative left of a zero line), so nothing is squashed into
/// a sliver the way a cost-anchored stacked bar is.
class _ReturnBars extends StatelessWidget {
  final YieldResult result;
  const _ReturnBars({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = returnContributions(result);
    return SizedBox(
      height: rows.length * 30.0 + 8,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ReturnBarsPainter(
          rows: rows,
          gain: gainColor(theme),
          loss: lossColor(theme),
          zero: theme.dividerColor,
          textColor: theme.colorScheme.onSurface,
          mutedColor: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ReturnBarsPainter extends CustomPainter {
  final List<ReturnContribution> rows;
  final Color gain, loss, zero, textColor, mutedColor;
  _ReturnBarsPainter({
    required this.rows,
    required this.gain,
    required this.loss,
    required this.zero,
    required this.textColor,
    required this.mutedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    final n = rows.length;
    final rowH = size.height / n;

    // Axis spans [min(0,…), max(0,…)] so zero sits where the signs cross.
    var lo = 0.0, hi = 0.0;
    for (final r in rows) {
      if (r.value < lo) lo = r.value;
      if (r.value > hi) hi = r.value;
    }
    if (hi == lo) hi = lo + 1;
    final range = hi - lo;

    const labelW = 104.0;
    const valueW = 64.0;
    final barLeft = labelW;
    final barW = (size.width - labelW - valueW).clamp(40.0, size.width);
    double xOf(double v) => barLeft + barW * (v - lo) / range;
    final xZero = xOf(0);

    // Faint zero baseline behind the bars.
    canvas.drawLine(
      Offset(xZero, 2),
      Offset(xZero, size.height - 2),
      Paint()
        ..color = zero
        ..strokeWidth = 1,
    );

    for (var i = 0; i < n; i++) {
      final r = rows[i];
      final cy = i * rowH + rowH / 2;
      final color = r.value >= 0 ? gain : loss;
      final barH = (rowH * 0.46).clamp(7.0, 16.0);

      // Separator above the net (summary) row.
      if (r.isNet) {
        canvas.drawLine(
          Offset(0, i * rowH),
          Offset(size.width, i * rowH),
          Paint()
            ..color = zero
            ..strokeWidth = 1,
        );
      }

      // Bar from the zero line out to the value.
      final x1 = xOf(r.value);
      final rect = Rect.fromLTRB(
        x1 < xZero ? x1 : xZero,
        cy - barH / 2,
        x1 < xZero ? xZero : x1,
        cy + barH / 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = r.isNet ? color : color.withValues(alpha: 0.85),
      );

      // Label (left column) and value (right column).
      _text(
        canvas,
        r.label,
        0,
        labelW - 8,
        cy,
        r.isNet ? textColor : mutedColor,
        bold: r.isNet,
        alignRight: false,
      );
      _text(
        canvas,
        _signedMoney(r.value),
        size.width - valueW,
        valueW,
        cy,
        color,
        bold: r.isNet,
        alignRight: true,
      );
    }
  }

  void _text(
    Canvas canvas,
    String s,
    double left,
    double width,
    double cy,
    Color color, {
    required bool bold,
    required bool alignRight,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: width);
    final dx = alignRight ? left + width - tp.width : left;
    tp.paint(canvas, Offset(dx, cy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_ReturnBarsPainter old) => old.rows != rows;
}

class _StatusChip extends StatelessWidget {
  final bool qualifies;
  const _StatusChip({required this.qualifies});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isOk = qualifies;
    final bg = isOk
        ? gainColor(theme).withValues(alpha: 0.18)
        : scheme.errorContainer;
    final fg = isOk ? gainColor(theme) : scheme.onErrorContainer;
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

// A compact 2-up grid of labelled figures — fills the width better than a
// column of label-left / value-right rows. Used for the Distributions/Prices
// tab summaries. Values shrink-to-fit so big numbers never overflow.
class _StatGrid extends StatelessWidget {
  final List<({String label, String value, Color? color})> stats;
  const _StatGrid(this.stats);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(({String label, String value, Color? color}) s) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              s.value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: s.color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
    return Column(
      children: [
        for (var i = 0; i < stats.length; i += 2)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cell(stats[i])),
                const SizedBox(width: 12),
                Expanded(
                  child: i + 1 < stats.length
                      ? cell(stats[i + 1])
                      : const SizedBox(),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// "Show your work" grid: the raw Price/Shares/NAV/Cost-basis/Unrealized-G/L the
// statement above is computed from, across the start (~1y ago) and current month.
class _ReferenceGrid extends StatelessWidget {
  final YieldResult result;
  const _ReferenceGrid({required this.result});

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
          endColor: signColor(theme, r.unrealizedGL),
        ),
      ],
    );
  }
}

// "Show your work" for a multi-lot portfolio: one row per lot (buy date, shares
// bought → now, cost, value, G/L) plus a totals row. Replaces the single-share
// reference grid when the user enters real lots.
class _PortfolioGrid extends StatelessWidget {
  final YieldResult result;
  const _PortfolioGrid({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    final headStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final numStyle = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // Right-aligned numeric cell; FittedBox shrinks a too-wide figure (big
    // portfolios) instead of letting it overflow or wrap.
    Widget numCell(String t, {Color? color, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text(
            t,
            style: numStyle?.copyWith(
              color: color,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );

    Widget headCell(String t, {bool left = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Text(
        t,
        textAlign: left ? TextAlign.left : TextAlign.right,
        style: headStyle,
      ),
    );

    Widget labelCell(String t, {bool bold = false, bool italic = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          child: Text(
            t,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: bold ? FontWeight.w700 : null,
              fontStyle: italic ? FontStyle.italic : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        );

    TableRow lotRow(LotResult l) => TableRow(
      children: [
        labelCell(
          l.isClosed
              ? '${_monthLabel(l.buyDate)}→${_monthLabel(l.sellDate!)}'
              : _monthLabel(l.buyDate),
          italic: l.isClosed,
        ),
        numCell('${fmtShares1(l.initialShares)}→${fmtShares1(l.finalShares)}'),
        numCell(_money0(l.cost)),
        numCell(_money0(l.nav)),
        numCell(_signedMoney0(l.gl), color: signColor(theme, l.gl)),
      ],
    );

    return Table(
      // Even flex columns spread the row across the full width instead of
      // clustering the numbers on the right of a wide window.
      columnWidths: const {
        0: FlexColumnWidth(2.4),
        1: FlexColumnWidth(2.2),
        2: FlexColumnWidth(1.7),
        3: FlexColumnWidth(1.7),
        4: FlexColumnWidth(1.7),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            headCell('Lot', left: true),
            headCell('Shares'),
            headCell('Cost'),
            headCell('Value'),
            headCell('G/L'),
          ],
        ),
        for (final l in r.lots) lotRow(l),
        TableRow(
          children: [
            labelCell('Total', bold: true),
            numCell(
              '${fmtShares1(r.totalInitialShares)}→${fmtShares1(r.totalFinalShares)}',
              bold: true,
            ),
            numCell(_money0(r.totalCost), bold: true),
            numCell(_money0(r.nav), bold: true),
            numCell(
              _signedMoney0(r.unrealizedGL + r.realizedGL),
              color: signColor(theme, r.unrealizedGL + r.realizedGL),
              bold: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// A compact price line over the fetched window with a tick under each
/// distribution date. Pure paint, no dependencies.
class _PriceSparkline extends StatelessWidget {
  final YieldResult result;
  const _PriceSparkline({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Ascending bars with a non-null close; the line needs at least two points.
    final bars = [...result.priceBars]
      ..sort((a, b) => a.date.compareTo(b.date));
    final pts = <({DateTime date, double close})>[
      for (final b in bars)
        if (b.close != null) (date: b.date, close: b.close!),
    ];
    if (pts.length < 2) return const SizedBox.shrink();
    final divDates = [for (final d in result.distributions) d.date];
    return SizedBox(
      height: 96,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklinePainter(
          points: pts,
          divDates: divDates,
          line: theme.colorScheme.primary,
          fill: theme.colorScheme.primary.withValues(alpha: 0.12),
          tick: theme.colorScheme.tertiary,
          textColor: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<({DateTime date, double close})> points;
  final List<DateTime> divDates;
  final Color line, fill, tick, textColor;
  _SparklinePainter({
    required this.points,
    required this.divDates,
    required this.line,
    required this.fill,
    required this.tick,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    const labelH = 14.0; // endpoint price labels at the bottom
    const tickH = 6.0; // distribution tick band above the labels
    final chartH = size.height - labelH - tickH;
    final t0 = points.first.date.millisecondsSinceEpoch.toDouble();
    final t1 = points.last.date.millisecondsSinceEpoch.toDouble();
    final span = (t1 - t0) == 0 ? 1.0 : (t1 - t0);
    var hi = points.first.close, lo = points.first.close;
    for (final p in points) {
      if (p.close > hi) hi = p.close;
      if (p.close < lo) lo = p.close;
    }
    if (hi == lo) hi = lo + 1;
    double x(DateTime d) =>
        ((d.millisecondsSinceEpoch - t0) / span) * size.width;
    double y(double v) => ((hi - v) / (hi - lo)) * chartH;

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final px = x(points[i].date);
      final py = y(points[i].close);
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    // Soft fill under the line.
    final fillPath = Path.from(path)
      ..lineTo(x(points.last.date), chartH)
      ..lineTo(x(points.first.date), chartH)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );

    // Distribution ticks just below the chart.
    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 1.5;
    for (final d in divDates) {
      final ms = d.millisecondsSinceEpoch.toDouble();
      if (ms < t0 || ms > t1) continue;
      final tx = x(d);
      canvas.drawLine(
        Offset(tx, chartH + 1),
        Offset(tx, chartH + tickH),
        tickPaint,
      );
    }

    // Endpoint price labels.
    _label(
      canvas,
      _money(points.first.close),
      0,
      size.height - labelH + 1,
      textColor,
      TextAlign.left,
      size.width,
    );
    _label(
      canvas,
      _money(points.last.close),
      0,
      size.height - labelH + 1,
      textColor,
      TextAlign.right,
      size.width,
    );
  }

  void _label(
    Canvas canvas,
    String text,
    double left,
    double top,
    Color color,
    TextAlign align,
    double width,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final dx = align == TextAlign.right ? width - tp.width : left;
    tp.paint(canvas, Offset(dx, top));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.points != points || old.divDates != divDates;
}
