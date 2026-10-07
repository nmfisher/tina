import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'stdio_fake.dart';

void main() {
  test('confirmed exit signals the host and settles present and future input',
      () async {
    final io = FakeStdio();
    final screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    addTearDown(() {
      editor.close(reportLatency: false);
      screen.dispose();
      io.close();
    });
    final exit = editor.whenQuit;
    var signalled = false;
    unawaited(exit.then((_) => signalled = true));
    final line = editor.readLine('model > ');
    await pumpEventQueue();
    expect(editor.quitRequested, false);
    expect(signalled, false);
    editor.inject(ControlKey(ControlCode.ctrlC));
    if (!editor.quitRequested) editor.inject(ControlKey(ControlCode.ctrlC));
    await exit.timeout(const Duration(seconds: 1));
    expect(editor.quitRequested, true);
    expect(await line, isNull);
    expect(await editor.readLine('model > '), isNull);
  });
}
