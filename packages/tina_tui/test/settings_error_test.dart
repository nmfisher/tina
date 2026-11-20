/// The settings-open failure notice (commit 27): a swallowed error hid
/// the root cause under wasm behind a permissions hint. The notice now
/// carries the actual error, one sanitized line.
library;

import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test('the first line of the error survives, whitespace collapsed', () {
    expect(settingsErrorLine(const FormatException('boom\nsecond line')),
        'FormatException: boom');
    expect(settingsErrorLine('  spaced   out\tbadly  '), 'spaced out badly');
  });

  test('a long message is clipped with an ellipsis', () {
    final text = settingsErrorLine('x' * 300);
    expect(text.length, 161);
    expect(text.endsWith('…'), isTrue);
    expect(text.startsWith('xxx'), isTrue);
  });

  test('an error with no message still says something', () {
    expect(settingsErrorLine('   '), isNotEmpty);
    expect(settingsErrorLine(Object()), contains('Object'));
  });
}
