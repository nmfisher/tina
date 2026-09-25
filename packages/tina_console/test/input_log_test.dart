import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';

// The input log is what a freeze gets read back from: "who took this key" and
// "was anything being drawn". These tests pin the pieces a real freeze would be
// diagnosed from — the recorded owner, the once-per-run drop warning, the
// coalesced trail, and the "frame not closed" alarm.

/// A backend that never closes its frame, standing in for any future path that
/// skips `endFrame`. The screen must notice on its own.
class _NeverClosesFrames extends AnsiBackend {
  _NeverClosesFrames({required super.io, required super.ansi});

  @override
  void endFrame() {}
}

LineEditor _editor(FakeStdio io) {
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.yes,
  );
  return LineEditor(screen: screen, escapeTimeout: Duration.zero);
}

/// Let queued microtasks, the parser's zero escape timeout, and the editor's
/// deferred work all run.
Future<void> _settle() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

/// The `who=...` field of the last trail line.
String _lastWho(List<String> lines) {
  final withWho = lines.where((l) => l.contains(' who=')).toList();
  return withWho.isEmpty ? '' : withWho.last;
}

void main() {
  late Directory dir;
  late File trail;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;

  setUp(() async {
    InputLog.reset();
    dir = await Directory.systemTemp.createTemp('tina-input-log');
    trail = File('${dir.path}/trail.log');
    InputLog.setTraceFile(trail.path);
    records = [];
    sub = Logger.root.onRecord.listen(records.add);
    Logger.root.level = Level.ALL;
  });

  tearDown(() async {
    await sub.cancel();
    Logger.root.level = Level.INFO;
    InputLog.setTraceFile(null);
    InputLog.reset();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  List<String> trailLines() =>
      trail.existsSync() ? trail.readAsLinesSync() : const [];

  List<String> messagesMatching(String needle) =>
      records.map((r) => r.message).where((m) => m.contains(needle)).toList();

  group('the state line', () {
    test('omits empty fields and joins the rest with spaces', () {
      final line = InputLog.format({
        'chat_prompt_open': true,
        'queued_lines': null,
        'agent_busy': false,
        'frames_open': 0,
      });
      expect(line, 'chat_prompt_open=true agent_busy=false frames_open=0');
    });

    test('names a character key without quoting it into the line', () {
      expect(InputLog.describeKey(CharInput('a')), 'char(a)');
      expect(
          InputLog.describeKey(ControlKey(ControlCode.enter)), 'ctrl(enter)');
      expect(InputLog.describeKey(EscapeKey()), 'esc');
    });

    test('never puts pasted text in the log, only its length', () {
      final described = InputLog.describeKey(PasteInput('secret-token-12345'));
      expect(described, 'paste(18)');
      expect(described, isNot(contains('secret')));
    });
  });

  group('the per-key trail', () {
    test('is off unless asked for', () {
      InputLog.setTraceFile(null);
      InputLog.key(CharInput('a'), KeyHandledBy.chatBox, () => const {});
      expect(InputLog.tracing, isFalse);
      expect(trailLines(), isEmpty);
    });

    test('records where the key went', () {
      InputLog.key(CharInput('a'), KeyHandledBy.chatBox, () => const {'x': 1});
      final lines = trailLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('who=chatBox'));
      expect(lines.single, contains('key=char(a)'));
      expect(lines.single, contains('x=1'));
    });

    test('coalesces a fast burst to one line per second worth of keys', () {
      for (var i = 0; i < 25; i++) {
        InputLog.key(CharInput('a'), KeyHandledBy.queuedInput, () => const {});
      }
      final lines = trailLines();
      // 20 full lines, then a single "suppressed" marker; the rest are dropped.
      expect(lines, hasLength(InputLog.maxLinesPerSecond + 1));
      expect(lines.last, contains('suppressed'));
    });
  });

  group('a dropped key is visible without anyone asking', () {
    test('warns once when nothing handles a key, and again on recovery', () {
      InputLog.key(CharInput('a'), KeyHandledBy.nobody, () => const {});
      InputLog.key(CharInput('b'), KeyHandledBy.nobody, () => const {});
      InputLog.key(CharInput('c'), KeyHandledBy.nobody, () => const {});

      final warnings = messagesMatching('key dropped');
      expect(warnings, hasLength(1),
          reason: 'one warning per run of dropped keys, not one per key');
      expect(warnings.single, contains('char(a)'));

      InputLog.key(CharInput('d'), KeyHandledBy.chatBox, () => const {});
      expect(messagesMatching('handled again'), hasLength(1));
    });
  });

  group('where a real keypress goes', () {
    test('typing at the chat prompt reaches the chat box', () async {
      final io = FakeStdio();
      final editor = _editor(io);
      unawaited(editor.readLine('> '));
      await _settle();

      io.feedBytes(utf8.encode('a'));
      await _settle();

      expect(_lastWho(trailLines()), contains('who=chatBox'));
      editor.close(reportLatency: false);
    });

    test('typing while a prompt waits is recorded as openPrompt', () async {
      final io = FakeStdio();
      final editor = _editor(io);
      final pending = editor.readKey();
      await _settle();

      io.feedBytes(utf8.encode('x'));
      await _settle();

      expect(_lastWho(trailLines()), contains('who=openPrompt'));
      expect(await pending, isA<CharInput>(),
          reason: 'the prompt consumed the key instead of the chat buffer');
      editor.close(reportLatency: false);
    });

    test('typing with nothing armed is recorded as nobody, and warns',
        () async {
      final io = FakeStdio();
      final editor = _editor(io);
      // Arm then disarm the busy-turn capture window: the input stream stays
      // subscribed while no prompt owns the keyboard. This is the same gap the
      // REPL can sit in.
      editor.beginCancelMonitor(() {});
      editor.endCancelMonitor();

      io.feedBytes(utf8.encode('b'));
      await _settle();

      expect(_lastWho(trailLines()), contains('who=nobody'));
      expect(messagesMatching('key dropped'), hasLength(1));
      editor.close(reportLatency: false);
    });

    test('the state line names a waiting prompt and a hidden input row',
        () async {
      final io = FakeStdio();
      final editor = _editor(io);
      unawaited(editor.readKey());
      await _settle();

      final state = editor.currentState();
      expect(state['answering_prompt'], isTrue);
      expect(state['chat_prompt_open'], isFalse);
      expect(state['input_row_hidden'], isFalse);

      final withExtras = editor
        ..describeState = () => {'agent_busy': true, 'session': 's1'};
      expect(withExtras.currentState()['agent_busy'], isTrue);
      expect(withExtras.currentState()['session'], 's1');
      editor.close(reportLatency: false);
    });
  });

  group('the frame alarm', () {
    test('warns once when a frame is never closed', () async {
      final io = FakeStdio();
      final backend = _NeverClosesFrames(io: io, ansi: AnsiCapable.yes);
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: ScreenLayout.fromSize(80, 24, split: false),
      );

      screen.frame(() {});
      screen.frame(() {});

      final warnings = messagesMatching('frame not closed');
      expect(warnings, hasLength(1),
          reason: 'warned once per occurrence, not once per frame');
      expect(warnings.single, contains('frames_open=1'));
    });

    test('a closed frame says nothing', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.yes,
      );
      screen.frame(() {});
      expect(messagesMatching('frame not closed'), isEmpty);
    });
  });
}
