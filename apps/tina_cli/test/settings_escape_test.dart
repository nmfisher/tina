// Escape semantics while the settings panel is open and work is running.
//
// Reported behavior: Esc inside a settings submenu closes the whole panel and
// cancels the request that is in flight. Expected: Esc backs out one submenu
// level, only closes the panel at the top level, and never cancels running
// work; cancel remains Esc's job at the prompt (or double-Esc outside).
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/tui.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

final class _StalledProvider implements LlmProvider {
  @override
  String get model => 'stalled';
  final streams = <StreamController<StreamEvent>>[];

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    final stream = StreamController<StreamEvent>();
    streams.add(stream);
    return stream.stream;
  }

  void answer(int index, String text) {
    streams[index].add(
      MessageComplete(content: [TextBlock(text)], stopReason: 'end_turn'),
    );
    unawaited(streams[index].close());
  }

  @override
  void close() {
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}

void main() {
  late Directory root;
  late _StalledProvider provider;
  late FakeIo io;
  late Screen screen;
  late LineEditor editor;
  late Future<int> app;
  late TuiSession session;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('settings-escape-');
    provider = _StalledProvider();
    session = TuiSession.wrap(
      SessionAssembly.start(
        providerFactory: (_) => provider,
        options: AssemblyOptions(
          workingDirectory: root.path,
          configPath: '${root.path}/config',
          plugins: ['tina/chat-tui', 'tina/goals', 'test/compact'],
        ),
        registerPlugins: (registry) => registry.register(
          'test/compact',
          (context) => CompactionPlugin(
            id: 'test/compact',
            terminal: context.terminal,
            config: CompactionConfig(
              thresholdTokens: 0,
              keepRecentTokens: 1,
              minMessagesToCompact: 3,
            ),
          ),
          description: 'Compaction stub for assembly parity',
        ),
      ),
    );
    io = FakeIo();
    screen = fakeScreen(io);
    app = runTui(
      session,
      screen: screen,
      editorFor: (s) =>
          editor = LineEditor(screen: s, escapeTimeout: Duration.zero),
    );
    addTearDown(() async {
      provider.close();
      session.cancel();
      editor.inject(ControlKey(ControlCode.ctrlC));
      editor.inject(ControlKey(ControlCode.ctrlC));
      io.closeInput();
      await app.timeout(const Duration(seconds: 3));
      root.deleteSync(recursive: true);
    });
    await waitFor(() => editor.isEditing);
    editor.commandProvider = session.createView().commandCompletion;
  });

  String visible() {
    final terminal = VirtualTerminal(
      width: screen.layout.width,
      height: screen.layout.height,
    )..feed(io.written.toString());
    return List.generate(screen.layout.height, terminal.rowText).join('\n');
  }

  test('Esc in a submenu backs out one level and keeps work running', () async {
    final view = session.createView();
    final turn = view.submit('long running');
    await waitFor(() => provider.streams.length == 1);
    expect(view.busy, isTrue);

    // Open settings while the request is in flight.
    editor.inject(CharInput('/settings'));
    editor.inject(ControlKey(ControlCode.enter));
    await waitFor(() => editor.isReadingKey);
    await waitFor(() => visible().contains('Settings'));

    // Enter the Plugins submenu.
    editor.inject(CharInput('Plugins'));
    editor.inject(ControlKey(ControlCode.enter));
    try {
      await waitFor(() => visible().contains('✓ on in this scope'));
    } catch (_) {
      // ignore: avoid_print
      print('--- visible when opening Plugins submenu ---\n${visible()}');
      rethrow;
    }

    // Esc must leave the submenu, not the panel — and must not cancel work.
    editor.inject(EscapeKey());
    try {
      await waitFor(() => !visible().contains('✓ on in this scope'));
    } catch (_) {
      // ignore: avoid_print
      print('--- visible after Esc in Plugins submenu ---\n${visible()}');
      rethrow;
    }
    expect(editor.isReadingKey, isTrue,
        reason: 'Esc in a submenu must keep the settings panel open');
    expect(visible(), contains('Settings'));
    expect(view.busy, isTrue, reason: 'Esc in settings must not cancel work');
    expect(view.canCancel, isTrue);

    // Esc at the top level closes the panel; work keeps running.
    editor.inject(EscapeKey());
    await waitFor(() => !editor.isReadingKey);
    expect(view.busy, isTrue,
        reason: 'closing settings must not cancel running work');
    expect(view.canCancel, isTrue);

    // Esc at the prompt still cancels the request.
    editor.inject(EscapeKey());
    await turn.timeout(const Duration(seconds: 3));
    expect(session.host.session.turns.last.stopReason, StopReason.cancelled);
  });
}
