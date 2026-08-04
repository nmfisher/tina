import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

void main() {
  group('AnsiCapable', () {
    test('yes constant has useColor=true', () {
      expect(AnsiCapable.yes.useColor, isTrue);
    });

    test('no constant has useColor=false', () {
      expect(AnsiCapable.no.useColor, isFalse);
    });

    test('detect returns an AnsiCapable instance', () {
      // We can't control the test runner's environment, so just verify the
      // factory returns a valid instance without throwing.
      final cap = AnsiCapable.detect();
      expect(cap, isNotNull);
      expect(cap.useColor, isA<bool>());
    });
  });
}
