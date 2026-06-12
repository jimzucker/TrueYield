// Captures one PNG per tab for the README, driven on a booted simulator with
// deterministic mock data (no live network). Run:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart -d <simulator-id>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:true_yield/main.dart';

import '../test/yahoo_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture each tab', (tester) async {
    SharedPreferences.setMockInitialValues({});

    // A realistic YMAG-shaped year: ~53 weekly bars drifting $15.20 → $11.69,
    // a weekly distribution on each. The math is bar-shape agnostic.
    final base = DateTime.now();
    const n = 53;
    final dates = [
      for (var i = 0; i < n; i++)
        DateTime.utc(
          base.year,
          base.month,
          base.day,
        ).subtract(Duration(days: (n - 1 - i) * 7)),
    ];
    final closes = <double?>[
      for (var i = 0; i < n; i++) 15.20 + (11.69 - 15.20) * i / (n - 1),
    ];
    final dividends = <DateTime, double>{
      for (var i = 1; i < n; i++) dates[i]: 0.09 + 0.09 * ((i * 3) % 6) / 6,
    };
    final body = yahooChartJson(
      price: 11.69,
      months: dates,
      closes: closes,
      dividends: dividends,
    );
    final client = MockClient((req) async => http.Response(body, 200));

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: YieldScreen(client: client),
      ),
    );
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();

    Future<void> enter(String label, String text) async {
      await tester.enterText(find.widgetWithText(TextField, label), text);
      await tester.pump();
    }

    Future<void> calculate() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Calculate'));
      await tester.pumpAndSettle();
    }

    Future<void> shot(String tab, String name) async {
      await tester.tap(find.widgetWithText(Tab, tab));
      await tester.pumpAndSettle();
      await binding.takeScreenshot(name);
    }

    await enter('Ticker', 'YMAG');
    await enter('Federal %', '32');
    await enter('State %', '5');
    await calculate();

    // The no-lots (per-share TTM) Calculate view (we're already on this tab).
    await binding.takeScreenshot('calculate-result');

    // Add a lot back-dated ~a year so the lots views show real DRIP growth +
    // G/L. ensureVisible scrolls the form so the off-screen controls are hittable.
    final addLot = find.text('Add lot');
    await tester.ensureVisible(addLot);
    await tester.pumpAndSettle();
    await tester.tap(addLot);
    await tester.pumpAndSettle();
    final buyButton = find.textContaining('Buy ').first;
    await tester.ensureVisible(buyButton);
    await tester.pumpAndSettle();
    await tester.tap(buyButton);
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('15').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await calculate();

    // The rest (Distributions/Prices/Info/Diag are the same regardless of lots).
    await shot('Lots', 'lots');
    await shot('Distributions', 'distributions');
    await shot('Prices', 'prices');
    await shot('Info', 'info');
    await shot('Diag', 'diagnostics');
  });
}
