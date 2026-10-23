import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/tui.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart' show SessionView;

import 'app_test.dart' show FakeIo, fakeScreen, approvalUi;
import 'turn_rendering_test.dart' show waitFor;

final class _Provider implements LlmProvider {
  @override
  String get model => 'controlled';
  final streams = <StreamController<StreamEvent>>[];
  final cleanup = Completer<void>();
  bool stallNextCleanup = false;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    final stalled = stallNextCleanup;
    stallNextCleanup = false;
    final stream = StreamController<StreamEvent>(
      onCancel: stalled ? () => cleanup.future : null,
    );
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
    for (final stream in streams) unawaited(stream.close());
  }
}

final class _Fixture {
  _Fixture(
    this.root,
    this.provider,
    this.session,
    this.view,
    this.editor,
    this.app,
  );
  final Directory root;
  final _Provider provider;
  final TuiSession session;
  final SessionView view;
  final LineEditor editor;
  final Future<int> app;

  void escape() => editor.inject(EscapeKey());

  Future<void> seed() async {
    final first = view.submit('first');
    await waitFor(() => provider.streams.length == 1);
    provider.answer(0, 'first answer');
    await first;
  }
}

Future<_Fixture> _start(
  bool panels, {
  bool autoCompact = false,
  bool approvals = false,
}) async {
  final root = Directory.systemTemp.createTempSync('escape-cancellation-');
  final provider = _Provider();
  final session = TuiSession.wrap(
    SessionAssembly.start(
      providerFactory: (_) => provider,
      options: AssemblyOptions(
        workingDirectory: root.path,
        configPath: '${root.path}/config',
        plugins: [
          'tina/chat-tui',
          if (panels) 'tina/panels-tui',
          'tina/goals',
          'test/compact',
          if (approvals) ...['tina/tools', 'tina/mode-tui'],
        ],
      ),
      registerPlugins: (registry) => registry.register(
        'test/compact',
        (context) => CompactionPlugin(
          id: 'test/compact',
          terminal: context.terminal,
          config: CompactionConfig(
            thresholdTokens: autoCompact ? 1 : 0,
            keepRecentTokens: 1,
            minMessagesToCompact: 3,
          ),
        ),
        description: 'Compaction with a small test threshold',
      ),
    ),
  );
  final io = FakeIo();
  late LineEditor editor;
  final app = runTui(
    session,
    screen: fakeScreen(io),
    editorFor: (screen) =>
        editor = LineEditor(screen: screen, escapeTimeout: Duration.zero),
  );
  final view = session.createView();
  addTearDown(() async {
    if (!provider.cleanup.isCompleted) provider.cleanup.complete();
    provider.close();
    session.cancel();
    editor.inject(ControlKey(ControlCode.ctrlC));
    editor.inject(ControlKey(ControlCode.ctrlC));
    io.closeInput();
    await app.timeout(const Duration(seconds: 3));
    view.close();
    root.deleteSync(recursive: true);
  });
  await waitFor(() => editor.isEditing);
  editor.commandProvider = view.commandCompletion;
  editor.completionProvider = view.fileCompletion;
  return _Fixture(root, provider, session, view, editor, app);
}

void main() {
  for (final panels in [false, true]) {
    test(
      'Escape never starts compaction after cancellation (panels=$panels)',
      () async {
        final f = await _start(panels, autoCompact: true);
        await f.seed();
        final second = f.view.submit('cancel this turn');
        await waitFor(() => f.provider.streams.length == 2);
        f.escape();
        await second.timeout(const Duration(seconds: 3));
        expect(
          f.session.host.session.turns.last.stopReason,
          StopReason.cancelled,
        );
        expect(f.provider.streams, hasLength(2));
        expect(f.view.busy, isFalse);
        expect(f.view.canCancel, isFalse);
      },
    );

    for (final quit in [false, true]) {
      test('automatic compaction stops without provider cleanup '
          '(quit=$quit, panels=$panels)', () async {
        final f = await _start(panels, autoCompact: true);
        await f.seed();
        final second = f.view.submit('second');
        await waitFor(() => f.provider.streams.length == 2);
        f.provider.stallNextCleanup = true;
        f.provider.answer(1, 'second answer');
        await waitFor(() => f.provider.streams.length == 3);
        expect(f.view.busy, isTrue);
        expect(f.view.canCancel, isTrue);
        if (quit) {
          f.editor.inject(CharInput('/quit'));
          f.editor.inject(ControlKey(ControlCode.enter));
          await f.app.timeout(const Duration(seconds: 3));
        } else {
          f.escape();
        }
        await second.timeout(const Duration(seconds: 3));
        expect(f.provider.cleanup.isCompleted, isFalse);
        expect(f.provider.streams.last.hasListener, isFalse);
        expect(
          f.session.host.session.loop.log.whereType<CompactedEntry>(),
          isEmpty,
        );
        if (!quit) {
          expect(f.view.busy, isFalse);
          expect(f.view.canCancel, isFalse);
          // A late response cannot compact history after cancellation.
          f.provider.answer(2, 'late summary');
          final next = f.view.submit('cancel another turn');
          await waitFor(() => f.provider.streams.length == 4);
          f.escape();
          await next.timeout(const Duration(seconds: 3));
          expect(
            f.session.host.session.loop.log.whereType<CompactedEntry>(),
            isEmpty,
          );
        }
      });

      for (final command in ['/compact', '/goal check']) {
        test('$command stops without provider cleanup '
            '(quit=$quit, panels=$panels)', () async {
          final f = await _start(panels);
          if (command == '/compact') {
            await f.seed();
            final second = f.view.submit('second');
            await waitFor(() => f.provider.streams.length == 2);
            f.provider.answer(1, 'second answer');
            await second;
          } else {
            await f.view.submit('/goal finish the task');
          }
          final count = f.provider.streams.length;
          f.provider.stallNextCleanup = true;
          final pending = f.view.submit(command);
          await waitFor(() => f.provider.streams.length == count + 1);
          expect(f.view.canCancel, isTrue);
          if (quit) {
            f.editor.inject(CharInput('/quit'));
            f.editor.inject(ControlKey(ControlCode.enter));
            await f.app.timeout(const Duration(seconds: 3));
          } else {
            f.escape();
          }
          await pending.timeout(const Duration(seconds: 3));
          expect(f.provider.cleanup.isCompleted, isFalse);
          expect(f.provider.streams.last.hasListener, isFalse);
          if (!quit) {
            expect(f.view.busy, isFalse);
            expect(f.view.canCancel, isFalse);
          }
        });
      }
    }

    for (final draft in ['unsent draft', '/go']) {
      test(
        'Escape preserves "$draft" and stops work (panels=$panels)',
        () async {
          final f = await _start(panels);
          final turn = f.view.submit('first');
          await waitFor(() => f.provider.streams.length == 1);
          for (final rune in draft.runes) {
            f.editor.inject(CharInput(String.fromCharCode(rune)));
          }
          expect(f.editor.editState.buffer, draft);
          if (draft.startsWith('/')) {
            await waitFor(() => f.editor.isCompleting);
          }
          f.escape();
          await turn.timeout(const Duration(seconds: 3));
          // A rapid repeat after settlement must not count as idle double-Esc.
          f.escape();
          expect(f.editor.editState.buffer, draft);
          expect(f.editor.isCompleting, isFalse);
          expect(
            f.session.host.session.turns.single.stopReason,
            StopReason.cancelled,
          );
        },
      );
    }

    for (final deny in [false, true]) {
      test('approval ${deny ? "Deny continues" : "Escape cancels"} '
          '(panels=$panels)', () async {
        final f = await _start(panels, approvals: true);
        await f.session.commands['mode']!.handler('ask');
        final turn = f.view.submit('write a file');
        await waitFor(() => f.provider.streams.length == 1);
        f.editor.inject(CharInput('keep this draft'));
        f.provider.streams[0].add(
          const ToolCallStart(id: 'write', name: 'write'),
        );
        f.provider.streams[0].add(
          const MessageComplete(
            content: [
              ToolUseBlock(
                id: 'write',
                name: 'write',
                input: {'filePath': 'denied.txt', 'content': 'not written'},
              ),
            ],
            stopReason: 'tool_use',
          ),
        );
        await f.provider.streams[0].close();
        await waitFor(
          () => approvalUi(f.session).interaction.pending.firstOrNull != null,
        );
        if (deny) {
          f.editor.inject(CharInput('n'));
          await waitFor(() => f.provider.streams.length == 2);
          f.provider.answer(1, 'denied');
        } else {
          // Text held behind an approval is also an unsent draft.
          f.editor.inject(PasteInput(' and pasted text'));
          f.escape();
        }
        await turn.timeout(const Duration(seconds: 3));
        expect(f.provider.streams, hasLength(deny ? 2 : 1));
        expect(
          f.session.host.session.turns.single.stopReason,
          deny ? StopReason.complete : StopReason.cancelled,
        );
        expect(
          f.editor.editState.buffer,
          deny ? 'keep this draft' : 'keep this draft and pasted text',
        );
        expect(File('${f.root.path}/denied.txt').existsSync(), isFalse);
      });
    }
  }
}
