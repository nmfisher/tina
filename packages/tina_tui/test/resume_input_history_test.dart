import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

void main() {
  for (final panels in [true, false]) {
    test('resuming restores Up/Down input recall and draft (panels=$panels)',
        () async {
      final dir = Directory.systemTemp.createTempSync('tina-resume-input-');
      final config = File('${dir.path}/config')..writeAsStringSync('''
[default]
model = "scripted"
[plugins]
enabled = ["tina/persistence", "tina/chat-tui"${panels ? ', "tina/panels-tui"' : ''}]
''');
      final first = TuiAssembly.start(
          options: AssemblyOptions(
              configPath: config.path, workingDirectory: dir.path),
          providerFactory: (_) =>
              ScriptedProvider([scriptedReply('one'), scriptedReply('two')]));
      await first.host.send('first instruction');
      await first.host.send('second instruction');
      final id = first.host.session.id;
      // Clearing request context must not erase the user's editor history.
      first.host.session.loop.clearHistory();
      first.close();
      final resumed = TuiSession.wrap(TuiAssembly.start(
          options: AssemblyOptions(
              configPath: config.path,
              workingDirectory: dir.path,
              sessionId: id),
          providerFactory: (_) => ScriptedProvider(const [])));
      final io = FakeIo();
      final screen = fakeScreen(io);
      late LineEditor editor;
      final app = runApp(resumed,
          screen: screen,
          editorFor: (screen) => editor = LineEditor(screen: screen));
      addTearDown(() async {
        io.feedBytes('\x03\x03\x03'.codeUnits);
        await app.timeout(const Duration(seconds: 4));
        io.closeInput();
        resumed.close();
        dir.deleteSync(recursive: true);
      });
      await waitFor(() => editor.isEditing);
      expect(resumed.inputHistory, ['first instruction', 'second instruction']);
      io.feedBytes('unfinished draft'.codeUnits);
      await waitFor(() => editor.editState.buffer == 'unfinished draft');
      io.feedBytes('\x1b[A'.codeUnits);
      await waitFor(() => editor.editState.buffer == 'second instruction');
      io.feedBytes('\x1b[A'.codeUnits);
      await waitFor(() => editor.editState.buffer == 'first instruction');
      io.feedBytes('\x1b[B'.codeUnits);
      await waitFor(() => editor.editState.buffer == 'second instruction');
      io.feedBytes('\x1b[B'.codeUnits);
      await waitFor(() => editor.editState.buffer == 'unfinished draft');
    });
  }
}
