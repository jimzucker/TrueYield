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
import 'package:url_launcher/url_launcher.dart';

import 'price_coverage.dart';
import 'roc_annual.dart';
import 'roc_data.dart';
import 'roc_history.dart';

part 'models.dart';
part 'yield_math.dart';
part 'yahoo.dart';
part 'roc.dart';
part 'format.dart';
part 'yield_screen.dart';
part 'result_card.dart';
part 'tabs.dart';

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
