import 'package:test/test.dart';
import 'package:tina_console/src/backend/terminfo_environment.dart';

void main() {
  test('macOS supplies installed system and Homebrew databases', () {
    final values = <String, String>{};
    configureMacosTerminfo(
      isMacOS: true,
      environment: {},
      directoryExists: (path) =>
          path == '/usr/share/terminfo' ||
          path == '/opt/homebrew/opt/ncurses/share/terminfo',
      setEnvironment: (key, value) => values[key] = value,
    );
    expect(values, {
      'TERMINFO_DIRS':
          '/usr/share/terminfo:/opt/homebrew/opt/ncurses/share/terminfo'
    });
  });
  test('explicit database settings and other platforms are untouched', () {
    for (final environment in [
      {'TERMINFO': '/custom'},
      {'TERMINFO_DIRS': '/custom'}
    ]) {
      configureMacosTerminfo(
          isMacOS: true,
          environment: environment,
          directoryExists: (_) => throw StateError('must honor override'),
          setEnvironment: (key, value) => fail('must honor override'));
    }
    configureMacosTerminfo(
        isMacOS: false,
        environment: {},
        directoryExists: (_) => throw StateError('not macOS'),
        setEnvironment: (key, value) => fail('not macOS'));
  });
  test('missing fallback directories leave native defaults unchanged', () {
    configureMacosTerminfo(
        isMacOS: true,
        environment: {},
        directoryExists: (_) => false,
        setEnvironment: (key, value) => fail('no installed database'));
  });
}
