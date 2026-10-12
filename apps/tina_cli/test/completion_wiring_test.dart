import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina/tui.dart';
import 'app_test.dart' show FakeIo;

void main() {
  late Directory ws;
  setUp(() {
    ws = Directory.systemTemp.createTempSync('tina-completion-');
  });
  tearDown(() => ws.deleteSync(recursive: true));
  group('wired through the app loop', () {
    test('the loop builds an editor whose / source names the registry and '
        'whose @ source completes real paths', () async {
      // A file for the @ source to find (the walk fallback supplies it —
      // the temp directory is not a git repository).
      File('${ws.path}/main.dart').writeAsStringSync('x\n');
      for (var i = 0; i < 240; i++) {
        File('${ws.path}/.tickets/ticket-$i.md')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      final provider = ScriptedProvider([scriptedReply('ack')]);
      final io = FakeIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => provider,
        workingDirectory: ws.path,
      );
      final done = runTui(
        session,
        screen: Screen(
          io: io,
          layout: ScreenLayout.fromSize(io.columns, io.lines),
        ),
      );
      Future<void> settle([int ms = 120]) =>
          Future<void>.delayed(Duration(milliseconds: ms));

      // '/mod' opens the command picker; Enter ACCEPTS '/mode ' and
      // dispatches it in one key. The tell proves the picker was fed
      // from the registry (a raw '/mod' would have answered 'unknown
      // command: /mod').
      await settle();
      io.feedBytes('/mod'.codeUnits);
      await settle(200); // let the refresh land before Enter
      io.feedBytes([0x0d]);
      await settle(200);

      // 'see @ma' opens the @ picker over the session's working
      // directory; Enter accepts the file candidate, a second Enter
      // submits the turn. The recorded request carries the completed
      // text — the @ source answered with a real path.
      io.feedBytes('see @ma'.codeUnits);
      await settle(200);
      io.feedBytes([0x0d]); // accept
      await settle(100);
      io.feedBytes([0x0d]); // submit
      await settle(200);

      // Buffer is empty again; '/quit' rides accept + submit.
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done.timeout(const Duration(seconds: 10)), 0);
      expect(
        session.assembly.quitRequested,
        isFalse,
        reason: 'quit is local to the frontend',
      );
      final told = (session.terminal as SessionTerminal).lines.map(
        (l) => l.text,
      );
      expect(
        told,
        contains('mode: ask'),
        reason: 'the / picker was fed from the Commands registry',
      );
      expect(
        provider.requests.last.messages.last.content
            .whereType<TextBlock>()
            .map((b) => b.text)
            .join(),
        contains('@main.dart'),
        reason: 'the @ picker was fed from the session working directory',
      );
    });
  });
}
