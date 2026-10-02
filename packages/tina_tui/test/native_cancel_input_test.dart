import 'dart:io';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart' as native;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

class NoPolledKeys extends native.KeySource {
  @override
  native.NcKeyEvent? poll() => null;
  @override
  void disposeKey(native.NcKeyEvent key) {}
}

void main() {
  for (final panels in [false, true]) {
    test('native backlog after Escape still submits Enter (panels=$panels)',
        () async {
      final directory =
          Directory.systemTemp.createTempSync('tina_native_cancel_');
      final config = File('${directory.path}/config')..writeAsStringSync('''
[default]
model="controlled"
[plugins]
enabled=["tina/chat-tui"${panels ? ', "tina/panels-tui"' : ''}]
''');
      final provider = ControlledProvider();
      final session = TuiSession.start(
          providerFactory: (_) => provider,
          workingDirectory: directory.path,
          configPath: config.path);
      final io = FakeIo();
      final input = native.NotcursesInputBackend(NoPolledKeys(),
          startupDrainMinWindow: Duration.zero,
          startupDrainMaxWindow: Duration.zero,
          startPolling: false);
      late LineEditor editor;
      final app = runApp(session,
          screen: fakeScreen(io),
          editorFor: (screen) =>
              editor = LineEditor(screen: screen, input: input));
      addTearDown(() async {
        session.host.session.loop.cancel('cleanup');
        editor.inject(ControlKey(ControlCode.ctrlC));
        editor.inject(ControlKey(ControlCode.ctrlC));
        await app.timeout(const Duration(seconds: 3));
        io.closeInput();
        directory.deleteSync(recursive: true);
      });
      input.pumpedInputForTest(nc.NcKey.resize);
      await waitFor(() => editor.isEditing);
      var time = 1000000000000;
      List<nc.PumpedInput> typing(String text) => [
            for (final unit in text.codeUnits)
              nc.PumpedInput(unit, 0, time += 100000000),
          ];
      // Keystrokes were captured 100ms apart on the native input thread,
      // but Dart receives the whole backlog together after a rendering stall.
      input.pumpedBatchForTest(typing('first\r'));
      await waitFor(() => provider.requests.length == 1);
      input.pumpedBatchForTest(typing('\x1breplacement\r'));
      await waitFor(() => provider.requests.length == 2);
      expect(session.inputHistory, ['first', 'replacement']);
      expect(session.host.session.turns.first.stopReason, StopReason.cancelled);
      provider.requests.last.add(const MessageComplete(
          content: [TextBlock('answer')], stopReason: 'end_turn'));
      await provider.requests.last.close();
      await waitFor(() => !session.host.session.loop.running);
    });
  }
}
