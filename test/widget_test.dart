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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:true_yield/main.dart';

import 'yahoo_fixture.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  testWidgets('app boots and shows the TrueYield title bar', (tester) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pump();
    expect(find.text('TrueYield'), findsOneWidget);
  });

  testWidgets('corrupt saved lots/ROC JSON does not crash boot', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'last_ticker': 'YMAG',
      'lots_by_ticker': '{ not valid json',
      'roc_overrides_by_ticker': 'also not json',
    });
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pumpAndSettle();
    expect(find.text('TrueYield'), findsOneWidget);
    expect(find.text('YMAG'), findsOneWidget); // other inputs still restored
  });

  testWidgets('Calculate tab renders the form and the Calculate button', (
    tester,
  ) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pump();

    expect(find.text('Ticker'), findsOneWidget);
    expect(find.text('Return of capital %'), findsOneWidget);
    expect(find.text('Federal %'), findsOneWidget);
    expect(find.text('State %'), findsOneWidget);
    expect(find.text('Local %'), findsOneWidget);
    // "Calculate" appears as both a tab label and the button label.
    expect(find.text('Calculate'), findsNWidgets(2));
  });

  testWidgets('six tabs are present', (tester) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pump();

    expect(find.byType(Tab), findsNWidgets(6));
    expect(find.widgetWithText(Tab, 'Calculate'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Lots'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Distributions'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Prices'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Info'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Diag'), findsOneWidget);
  });

  testWidgets('Diagnostics tab shows the holding-period scenarios', (
    tester,
  ) async {
    // Tall surface so all scenario cards build (the list is lazy otherwise).
    tester.view.physicalSize = const Size(1000, 5200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TrueYieldApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(Tab, 'Diag'));
    await tester.pumpAndSettle();

    expect(find.text('No lots'), findsOneWidget);
    expect(find.text('1 lot · 3 months'), findsOneWidget);
    expect(find.text('1 lot · 30 months'), findsOneWidget);
    expect(find.text('Multiple lots'), findsOneWidget);
    expect(find.text('Falling price'), findsOneWidget);
    // Passing scenarios collapse by default; expand one to reveal its detail.
    await tester.tap(find.text('No lots'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Total return after tax'), findsWidgets);
    // Every scenario self-checks against its expected values and passes.
    expect(find.text('FAIL'), findsNothing);
    expect(find.text('PASS'), findsWidgets);
  });

  testWidgets('Info tab explains how to use and read the app', (tester) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(Tab, 'Info'));
    await tester.pumpAndSettle();

    expect(find.text('How to use'), findsOneWidget);
    expect(find.text('Reading the result'), findsOneWidget);
    expect(find.text('Disclaimers'), findsOneWidget);
    expect(find.text('Project & README'), findsOneWidget);

    // Bundled ROC-data summary: funds / distributions / last updated.
    expect(find.text('Bundled ROC data'), findsOneWidget);
    expect(find.text('funds'), findsOneWidget);
    expect(find.text('distributions'), findsOneWidget);
    expect(find.textContaining('Updated '), findsOneWidget);
    // CSV download links moved to the Distributions/Prices tabs (see below).
  });

  testWidgets('empty data tabs show "Run Calculate to populate."', (
    tester,
  ) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(Tab, 'Distributions'));
    await tester.pumpAndSettle();
    expect(find.text('Run Calculate to populate.'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Prices'));
    await tester.pumpAndSettle();
    expect(find.text('Run Calculate to populate.'), findsOneWidget);
  });

  testWidgets('Calculate with empty ticker shows the validation card', (
    tester,
  ) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pump();

    // Tap the Calculate *button* (the one in the form, not the tab).
    await tester.tap(find.widgetWithText(FilledButton, 'Calculate'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a ticker.'), findsOneWidget);
  });

  testWidgets('Calculate with non-numeric tax rate shows numeric error', (
    tester,
  ) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'YMAG');
    await tester.enterText(find.widgetWithText(TextField, 'Federal %'), 'abc');
    await tester.tap(find.widgetWithText(FilledButton, 'Calculate'));
    await tester.pumpAndSettle();
    expect(
      find.text('Tax rates must be numeric (e.g. 32 for 32%).'),
      findsOneWidget,
    );
  });

  testWidgets('Calculate with out-of-range ROC shows the ROC error', (
    tester,
  ) async {
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'YMAG');
    await tester.enterText(find.widgetWithText(TextField, 'Federal %'), '32');
    await tester.enterText(find.widgetWithText(TextField, 'State %'), '5');
    await tester.enterText(
      find.widgetWithText(TextField, 'Return of capital %'),
      '150',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Calculate'));
    await tester.pumpAndSettle();
    expect(
      find.text('Return of capital % must be between 0 and 100.'),
      findsOneWidget,
    );
  });

  testWidgets('tapping a populated field selects all for type-over', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'last_ticker': 'YMAG',
    });
    await tester.pumpWidget(const TrueYieldApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, 'Ticker'));
    await tester.pumpAndSettle(); // let the post-frame select-all run

    final ticker = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Ticker'),
    );
    expect(
      ticker.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 4), // "YMAG"
    );
  });

  testWidgets('saved tax rates and ticker are restored on launch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'last_ticker': 'YMAG',
      'rate_federal': '32',
      'rate_state': '5',
      'rate_local': '0',
    });

    await tester.pumpWidget(const TrueYieldApp());
    await tester.pumpAndSettle();

    expect(find.text('YMAG'), findsOneWidget);
    expect(find.text('32'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });

  group('Calculate → render flow (mock client)', () {
    // Pump the screen with an injected client and let initState's
    // _loadSavedInputs settle first, so it can't overwrite text we enter next.
    Future<void> pumpScreen(WidgetTester tester, http.Client client) async {
      // A tall surface so the form (which grows as lots are added) and the
      // result card both fit without fighting the scroll position.
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: YieldScreen(client: client)));
      await tester.pumpAndSettle();
    }

    Future<void> calculate(
      WidgetTester tester, {
      required String ticker,
      String federal = '0',
      String state = '0',
    }) async {
      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), ticker);
      await tester.enterText(
        find.widgetWithText(TextField, 'Federal %'),
        federal,
      );
      await tester.enterText(find.widgetWithText(TextField, 'State %'), state);
      // With lots added the form can exceed the test viewport; scroll the
      // button into view before tapping.
      final button = find.widgetWithText(FilledButton, 'Calculate');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('successful Calculate renders the qualifying result card', (
      tester,
    ) async {
      Uri? requested;
      final client = MockClient((req) async {
        requested = req.url;
        return http.Response(
          yahooChartJson(
            price: 80,
            months: [
              DateTime.utc(2025, 6),
              DateTime.utc(2025, 12),
              DateTime.utc(2026, 6),
            ],
            closes: [100, 90, 80],
            dividends: {DateTime.utc(2025, 12, 15): 5.0},
          ),
          200,
        );
      });
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'test', federal: '32', state: '5');

      // Ticker normalized to upper case; endpoint params are as expected.
      expect(requested.toString(), contains('/chart/TEST?'));
      expect(requested.toString(), contains('interval=1d'));
      expect(requested.toString(), contains('range=1y'));

      // The qualifying card shows the ROC / total-return statement. (The
      // status chip only appears on the non-qualifying card.)
      expect(find.text('Total return after tax'), findsOneWidget);
      expect(find.text('Income (taxable)'), findsOneWidget);
      expect(find.text('Tax this year'), findsOneWidget);
      expect(find.text('After-tax yield'), findsOneWidget);
      expect(find.text('Advertised yield'), findsWidgets);
      expect(find.textContaining('TTM distributions'), findsWidgets);
      // The card is stamped with when it was fetched.
      expect(find.textContaining('As of'), findsOneWidget);
    });

    testWidgets('Distributions tab lists payouts after Calculate', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 100,
            months: [
              DateTime.utc(2025, 7),
              DateTime.utc(2025, 10),
              DateTime.utc(2026, 1),
            ],
            closes: [100, 100, 100],
            dividends: {
              DateTime.utc(2025, 7, 15): 1.0,
              DateTime.utc(2025, 10, 15): 2.0,
            },
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'PAY');

      await tester.tap(find.widgetWithText(Tab, 'Distributions'));
      await tester.pumpAndSettle();

      expect(find.text('Date'), findsOneWidget);
      expect(find.text('Amount'), findsOneWidget); // column header only now
      expect(find.text('Total (12mo)'), findsOneWidget);
      expect(find.textContaining('2 payouts'), findsOneWidget);
      // Summary uses the Calculate-tab labeled rows.
      expect(find.text('Total distributions'), findsOneWidget);
      expect(find.text('Average per payout'), findsOneWidget);
      expect(find.textContaining('Return of capital'), findsOneWidget);
      // Footer total = $1 + $2 = $3.00 (now formatted like the summary).
      expect(find.text('\$3.00'), findsWidgets);
    });

    testWidgets('Prices tab lists closes and shows — for a null bar', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 80,
            months: [
              DateTime.utc(2025, 6),
              DateTime.utc(2025, 12),
              DateTime.utc(2026, 6),
            ],
            closes: [100, null, 80],
            dividends: {DateTime.utc(2025, 12, 15): 5.0},
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'PRC');

      await tester.tap(find.widgetWithText(Tab, 'Prices'));
      await tester.pumpAndSettle();

      expect(find.text('Date'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('Current price'), findsOneWidget);
      expect(find.text('12-month change'), findsOneWidget);
      expect(find.text('Average close'), findsOneWidget);
      expect(find.text('—'), findsWidgets); // null close bar(s) show an em-dash
    });

    testWidgets('a non-payer renders the "Does not qualify" card', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 486.38,
            months: [DateTime.utc(2025, 6), DateTime.utc(2026, 5)],
            closes: [100, 110],
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'BRK-B', federal: '32', state: '5');

      expect(find.text('Does not qualify'), findsOneWidget); // status chip
      expect(
        find.textContaining('(no distributions in last 12 months)'),
        findsOneWidget,
      );

      // The Distributions tab shows the ticker-specific empty message.
      await tester.tap(find.widgetWithText(Tab, 'Distributions'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('no distributions in the last 12 months'),
        findsOneWidget,
      );
    });

    testWidgets('an HTTP error surfaces a "Lookup failed" message', (
      tester,
    ) async {
      final client = MockClient((req) async => http.Response('', 500));
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'ERR');

      expect(find.textContaining('Lookup failed: HTTP 500'), findsOneWidget);
    });

    testWidgets('entering a known ticker auto-fills its ROC from 19a-1', (
      tester,
    ) async {
      final client = MockClient((req) async => http.Response('', 500));
      await pumpScreen(tester, client);

      final expected = rocForTicker('MSTY');
      expect(expected, isNotNull); // MSTY is in the bundled table
      final wanted = expected! == expected.roundToDouble()
          ? expected.toStringAsFixed(0)
          : expected.toString();

      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'MSTY');
      await tester.pumpAndSettle();

      final roc = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Return of capital %'),
      );
      expect(roc.controller!.text, wanted);
      // The source caption names the fund.
      expect(find.textContaining('MSTY’s 19a-1'), findsOneWidget);
    });

    testWidgets('adding two lots renders the portfolio grid', (tester) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 100,
            months: [
              DateTime.utc(2025, 7),
              DateTime.utc(2025, 10),
              DateTime.utc(2026, 1),
            ],
            closes: [100, 100, 100],
            dividends: {
              DateTime.utc(2025, 7, 15): 1.0,
              DateTime.utc(2025, 10, 15): 1.0,
            },
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);

      // No lots yet → the default-lot hint is shown.
      expect(find.textContaining('Default: 1 share'), findsOneWidget);

      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove lot'), findsNWidgets(2));

      // Each lot has a Shares/Price/Cost-basis row and an open sell control.
      expect(find.widgetWithText(TextField, 'Shares'), findsNWidgets(2));
      expect(find.widgetWithText(TextField, 'Price'), findsNWidgets(2));
      expect(find.text('Cost basis'), findsNWidgets(2));
      expect(
        find.widgetWithText(OutlinedButton, 'Add sell date'),
        findsNWidgets(2),
      );

      await calculate(tester, ticker: 'PORT', federal: '32', state: '5');

      // Two lots → the portfolio grid (header + totals) instead of the
      // single-share reference grid.
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('Value'), findsOneWidget);
      expect(find.textContaining('across 2 lots'), findsOneWidget);
    });

    testWidgets('a single lot uses the portfolio view, not the TTM one', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 100,
            months: [DateTime.utc(2025, 7), DateTime.utc(2026, 1)],
            closes: [100, 100],
            dividends: {
              DateTime.utc(2025, 7, 15): 1.0,
              DateTime.utc(2026, 1, 15): 1.0,
            },
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      await calculate(tester, ticker: 'ONE', federal: '32', state: '5');

      // One real lot is still a portfolio: dollar header + per-lot grid, and
      // none of the per-share TTM lines that misrepresented it before.
      expect(find.text('Distributions received'), findsOneWidget);
      expect(find.textContaining('across 1 lot'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('TTM distributions'), findsNothing);
      expect(find.text('Advertised yield'), findsNothing);
    });

    testWidgets('Lots tab shows per-lot detail after Calculate', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 100,
            months: [
              DateTime.utc(2025, 7),
              DateTime.utc(2025, 10),
              DateTime.utc(2026, 1),
            ],
            closes: [100, 100, 100],
            dividends: {
              DateTime.utc(2025, 7, 15): 1.0,
              DateTime.utc(2025, 10, 15): 1.0,
            },
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      await calculate(tester, ticker: 'PORT', federal: '32', state: '5');

      await tester.tap(find.widgetWithText(Tab, 'Lots'));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 lots'), findsOneWidget);
      expect(find.text('Principal (cost)'), findsNWidgets(2));
      expect(find.text('Total return (after tax)'), findsNWidgets(2));
      expect(find.text('Open'), findsNWidgets(2)); // both lots still held
    });

    testWidgets('lots are saved per ticker and swap when the ticker changes', (
      tester,
    ) async {
      final client = MockClient((req) async => http.Response('', 500));
      await pumpScreen(tester, client);

      // Ticker AAA with one lot.
      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'AAA');
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove lot'), findsOneWidget);

      // Switch to BBB and blur the ticker field → its (empty) lots load.
      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'BBB');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove lot'), findsNothing);

      // Back to AAA → its saved lot is restored.
      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'AAA');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove lot'), findsOneWidget);
    });

    testWidgets('a lot with no quantity shows a validation error', (
      tester,
    ) async {
      final client = MockClient((req) async => http.Response('', 500));
      await pumpScreen(tester, client);
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      // Clear the seeded quantity.
      await tester.enterText(find.widgetWithText(TextField, 'Shares'), '');
      await calculate(tester, ticker: 'NOQTY');
      expect(find.textContaining('positive quantity'), findsOneWidget);
    });

    testWidgets('a new lot defaults its Price to the last close', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 90,
            months: [
              DateTime.utc(2025, 6),
              DateTime.utc(2025, 12),
              DateTime.utc(2026, 6),
            ],
            closes: [100, 95, 90], // last close = 90
            dividends: {DateTime.utc(2025, 12, 15): 5.0},
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      // Enter a ticker and blur → background prefetch loads the price bars.
      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'PRC');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      // A new lot pre-fills its Price with the last close (90).
      await tester.tap(find.text('Add lot'));
      await tester.pumpAndSettle();
      final price = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Price'),
      );
      expect(price.controller!.text, '90');
    });

    testWidgets('Distributions tab exposes an editable ROC % column', (
      tester,
    ) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 100,
            months: [DateTime.utc(2025, 7), DateTime.utc(2026, 1)],
            closes: [100, 100],
            dividends: {
              DateTime.utc(2025, 7, 15): 1.0,
              DateTime.utc(2026, 1, 15): 1.0,
            },
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'ROCED', federal: '32', state: '5');

      await tester.tap(find.widgetWithText(Tab, 'Distributions'));
      await tester.pumpAndSettle();
      expect(find.text('ROC %'), findsOneWidget);
    });

    testWidgets('editing an input clears a stale result', (tester) async {
      final client = MockClient(
        (req) async => http.Response(
          yahooChartJson(
            price: 80,
            months: [
              DateTime.utc(2025, 6),
              DateTime.utc(2025, 12),
              DateTime.utc(2026, 6),
            ],
            closes: [100, 90, 80],
            dividends: {DateTime.utc(2025, 12, 15): 5.0},
          ),
          200,
        ),
      );
      await pumpScreen(tester, client);
      await calculate(tester, ticker: 'TEST', federal: '32', state: '5');
      expect(find.text('Total return after tax'), findsOneWidget);

      // Changing any input drops the now-stale card so it can't mislead.
      await tester.enterText(
        find.widgetWithText(TextField, 'Return of capital %'),
        '50',
      );
      await tester.pump();
      expect(find.text('Total return after tax'), findsNothing);
    });
  });
}
