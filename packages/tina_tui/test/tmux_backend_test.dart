// The tmux ANSI fallback: `auto` inside tmux selects the ANSI backend and
// says so on the status strip; outside tmux, and with an explicit
// `--backend`, nothing changes. The resolver is tested pure; the strip
// tests drive runApp over a fake screen like app_test.dart.
library;

import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:test/test.dart';

import 'app_test.dart' show FakeIo, NoKeys, fakeScreen, scriptedConsole;

void main() {
  late Directory ws;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_tui_tmux_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  group('resolveBackendSelection', () {
    test('auto inside tmux falls back to ANSI with a notice', () {
      final picked = resolveBackendSelection('auto',
          environment: const {'TMUX': '/tmp/tmux-501/default,12345,0'});
      expect(picked.backend, 'ansi');
      expect(picked.tmuxNotice, isNotNull);
      expect(picked.tmuxNotice, contains('--backend ansi'));
    });

    test('auto outside tmux keeps the default and stays silent', () {
      for (final environment in [
        null,
        const <String, String>{},
        const {'TMUX': ''},
      ]) {
        final picked =
            resolveBackendSelection('auto', environment: environment);
        expect(picked.backend, 'auto');
        expect(picked.tmuxNotice, isNull);
      }
    });

    test('an explicit backend wins inside tmux without a notice', () {
      for (final backend in ['ansi', 'notcurses']) {
        final picked = resolveBackendSelection(backend,
            environment: const {'TMUX': '/tmp/tmux-501/default,12345,0'});
        expect(picked.backend, backend);
        expect(picked.tmuxNotice, isNull);
      }
    });
  });

  group('the status bar names the backend and the tmux fallback', () {
    /// One startup through runApp over a fake screen; returns everything
    /// the screen painted. The injected screen is ANSI, so the strip's
    /// backend label reads `ansi` throughout — the resolver decides only
    /// whether the notice rides along.
    Future<String> paintedStrip(
        {required String backend, String? tmux}) async {
      final io = FakeIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => ScriptedProvider(const []),
        workingDirectory: ws.path,
      );
      final done = runApp(
        session,
        screen: fakeScreen(io),
        consoleContextFor: scriptedConsole(NoKeys.new),
        backend: backend,
        environment: {
          if (tmux != null) 'TMUX': tmux,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(io.written.toString(), contains('mode: ask'),
          reason: 'the mode strip must be visible at 80 columns');
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
      return io.written.toString();
    }

    test('tmux plus auto binds the notice next to the ansi label', () async {
      final painted = await paintedStrip(
          backend: 'auto', tmux: '/tmp/tmux-501/default,12345,0');
      expect(painted, contains('ansi'));
      expect(painted,
          contains('tmux: --backend ansi renders more predictably'));
    });

    test('outside tmux the strip shows the plain backend label', () async {
      final painted = await paintedStrip(backend: 'auto');
      expect(painted, contains('ansi'));
      expect(painted, isNot(contains('renders more predictably')));
    });

    test('an explicit backend suppresses the notice inside tmux', () async {
      final painted = await paintedStrip(
          backend: 'ansi', tmux: '/tmp/tmux-501/default,12345,0');
      expect(painted, contains('ansi'));
      expect(painted, isNot(contains('renders more predictably')));
    });
  });
}
