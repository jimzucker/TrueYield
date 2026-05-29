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

import 'package:flutter_test/flutter_test.dart';
import 'package:true_yield/main.dart';

void main() {
  group('resolveYahooBase — CORS proxy is web-only', () {
    const proxy = 'https://trueyield-proxy.example.workers.dev';

    test('native (iOS/Android/desktop) always calls Yahoo directly', () {
      // The whole point: a native build must never route through the proxy,
      // even if a YAHOO_PROXY value is somehow present in the build.
      expect(resolveYahooBase(isWeb: false, proxy: proxy), kYahooDirect);
      expect(resolveYahooBase(isWeb: false, proxy: ''), kYahooDirect);
    });

    test('web uses the proxy when one is configured', () {
      expect(resolveYahooBase(isWeb: true, proxy: proxy), proxy);
    });

    test('web with no proxy falls back to Yahoo directly', () {
      expect(resolveYahooBase(isWeb: true, proxy: ''), kYahooDirect);
    });
  });
}
