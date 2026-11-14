import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

void main() {
  test('override beats detection', () {
    expect(
        ImageColorCapabilities.detect(
            override: 'truecolor', colorterm: '', term: 'xterm'),
        ImageColorMode.truecolor);
    expect(
        ImageColorCapabilities.detect(
            override: '256', colorterm: 'truecolor', term: ''),
        ImageColorMode.indexed256);
    expect(
        ImageColorCapabilities.detect(
            override: 'off', colorterm: 'truecolor', term: '256color'),
        ImageColorMode.mono);
  });

  test('COLORTERM truecolor/24bit/yes wins over TERM', () {
    for (final value in ['truecolor', '24bit', 'TrueColor', 'yes']) {
      expect(
          ImageColorCapabilities.detect(
              colorterm: value, term: 'xterm-256color'),
          ImageColorMode.truecolor,
          reason: 'COLORTERM=$value');
    }
  });

  test('TERM direct is truecolor, TERM 256color is indexed', () {
    expect(ImageColorCapabilities.detect(colorterm: null, term: 'xterm-direct'),
        ImageColorMode.truecolor);
    expect(
        ImageColorCapabilities.detect(colorterm: null, term: 'xterm-256color'),
        ImageColorMode.indexed256);
    expect(
        ImageColorCapabilities.detect(
            colorterm: null, term: 'screen-256color'),
        ImageColorMode.indexed256);
  });

  test('plain terminals degrade to mono', () {
    expect(ImageColorCapabilities.detect(colorterm: null, term: 'xterm'),
        ImageColorMode.mono);
    expect(ImageColorCapabilities.detect(colorterm: null, term: null),
        ImageColorMode.mono);
    expect(
        ImageColorCapabilities.detect(colorterm: '1', term: 'vt100'),
        ImageColorMode.mono);
  });

  test('an unparsable override falls through to detection, not mono', () {
    expect(
        ImageColorCapabilities.detect(
            override: 'maybe', colorterm: 'truecolor', term: null),
        ImageColorMode.truecolor);
    expect(
        ImageColorCapabilities.detect(
            override: 'maybe', colorterm: null, term: 'xterm-256color'),
        ImageColorMode.indexed256);
  });
}
