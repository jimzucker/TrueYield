// Driver for the screenshot integration test: writes each captured PNG to
// docs/screenshots/. See integration_test/screenshots_test.dart.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final file = File('docs/screenshots/$name.png');
      await file.writeAsBytes(bytes);
      return true;
    },
  );
}
