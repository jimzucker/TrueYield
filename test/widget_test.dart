// Copyright 2026 Jim Zucker
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
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iyield/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  testWidgets('app boots and shows the iYield title bar', (tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();
    expect(find.text('iYield'), findsOneWidget);
  });

  testWidgets('Calculate tab renders the form and the Calculate button',
      (tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();

    expect(find.text('Ticker'), findsOneWidget);
    expect(find.text('Federal marginal rate (%)'), findsOneWidget);
    expect(find.text('State marginal rate (%)'), findsOneWidget);
    expect(find.text('Local/city marginal rate (%)'), findsOneWidget);
    // "Calculate" appears as both a tab label and the button label.
    expect(find.text('Calculate'), findsNWidgets(2));
  });

  testWidgets('three tabs are present', (tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();

    expect(find.byType(Tab), findsNWidgets(3));
    expect(find.widgetWithText(Tab, 'Calculate'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Distributions'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Prices'), findsOneWidget);
  });

  testWidgets('empty data tabs show "Run Calculate to populate."',
      (tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(Tab, 'Distributions'));
    await tester.pumpAndSettle();
    expect(find.text('Run Calculate to populate.'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Prices'));
    await tester.pumpAndSettle();
    expect(find.text('Run Calculate to populate.'), findsOneWidget);
  });

  testWidgets('Calculate with empty ticker shows the validation card',
      (tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();

    // Tap the Calculate *button* (the one in the form, not the tab).
    await tester.tap(find.widgetWithText(FilledButton, 'Calculate'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a ticker.'), findsOneWidget);
  });

  testWidgets('Calculate with non-numeric tax rate shows numeric error',
      (tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'YMAG');
    await tester.enterText(
        find.widgetWithText(TextField, 'Federal marginal rate (%)'), 'abc');
    await tester.tap(find.widgetWithText(FilledButton, 'Calculate'));
    await tester.pumpAndSettle();
    expect(find.text('Tax rates must be numeric (e.g. 32 for 32%).'),
        findsOneWidget);
  });

  testWidgets('saved tax rates and ticker are restored on launch',
      (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'last_ticker': 'YMAG',
      'rate_federal': '32',
      'rate_state': '5',
      'rate_local': '0',
    });

    await tester.pumpWidget(const IYieldApp());
    await tester.pumpAndSettle();

    expect(find.text('YMAG'), findsOneWidget);
    expect(find.text('32'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });
}
