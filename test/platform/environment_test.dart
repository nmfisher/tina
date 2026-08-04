import 'dart:io';

import 'package:tina/platform/environment.dart';
import 'package:test/test.dart';

void main() {
  group('Environment', () {
    test('PlatformEnvironment mirrors Platform exactly', () {
      const env = PlatformEnvironment();
      expect(env.env, same(Platform.environment));
      expect(env.operatingSystem, Platform.operatingSystem);
      expect(env.isMacOS, Platform.isMacOS);
      expect(env.isWindows, Platform.isWindows);
      expect(env.isLinux, Platform.isLinux);
    });

    test('PlatformEnvironment reads live env vars', () {
      // PATH is set on every supported host platform.
      expect(const PlatformEnvironment().env['PATH'], isNotNull);
    });
  });
}
