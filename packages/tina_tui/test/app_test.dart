// The app: entry-point wiring completeness and the render loop, driven
// through a local fake Stdio and a real Screen over it. No TTY
// required: raw mode is skipped (no controlling terminal), events are
// fed as bytes.
//
// The TTY smoke test lives in app_smoke_test.dart, tagged `tty` and
// skipped by default — the wiring tests here run everywhere.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:test/test.dart';

/// A fake [Stdio]: an in-memory byte feed for input, a captured buffer
/// for output — the same seam [LiveStdio] fills on a real terminal.
final class FakeIo implements Stdio {
  final _controller = StreamController<List<int>>(sync: true);
  final written = StringBuffer();
  int columns = 80;
  final lines = 24;

  void feedBytes(List<int> bytes) => _controller.add(bytes);

  void closeInput() => _controller.close();

  @override
  Stream<List<int>> get stdin => _controller.stream;

  @override
  void write(String s) => written.write(s);

  @override
  int get terminalColumns => columns;

  @override
  bool get hasTerminal => false;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) =>
      const Stream<ProcessSignal>.empty();
}

/// A capture terminal — the Terminal contract, recording lines.
final class CaptureTerminal implements Terminal {
  final lines = <String>[];
  final prompts = <String>[];
  Queue<String>? queue;

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) {
    prompts.add(prompt);
    return Future<String>.value(queue?.removeFirst() ?? '');
  }
}

/// A screen over [FakeIo] — the app renders into memory, the loop reads
/// bytes from [FakeIo.feedBytes]. An ANSI screen (no passthrough) so the
/// full-screen path — alt screen, frames, overlay — is the tested path.
Screen fakeScreen(FakeIo io) => Screen(
      io: io,
      layout: ScreenLayout.fromSize(io.columns, io.lines),
    );

/// A key source with nothing to give — the closed-source denial path.
final class NoKeys implements KeySource {
  const NoKeys();

  @override
  Future<ApprovalKey?> next() async => null;
}

/// Feed [line] to [io] once [until] turns true (polled, since the loop
/// arms its reader asynchronously). Never hangs forever: a watchdog
/// completes the waiter too.
Future<void> feedWhen(
    FakeIo io, String line, Future<bool> Function() until) async {
  var ok = false;
  var waited = 0;
  while (!ok && waited < 5000) {
    ok = await until().timeout(const Duration(seconds: 5),
        onTimeout: () => Future<bool>.value(true));
    if (!ok) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      waited += 20;
    }
  }
  io.feedBytes('$line\r'.codeUnits);
}

void main() {
  late Directory ws;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_tui_app_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  group('explicit terminal wiring', () {
    test('the assembly and session share one buffered terminal', () {
      final assembly = TuiAssembly.start(
        providerFactory: (_) => ScriptedProvider(const []),
        options: AssemblyOptions(
            configPath: '/nonexistent/tina/config', workingDirectory: ws.path),
      );
      expect(assembly.terminal, isA<TuiTerminal>(),
          reason: 'the default terminal buffers output without terminal I/O');
      final session = TuiSession.wrap(assembly);
      expect(session.terminal, isA<TuiTerminal>(),
          reason: 'TuiSession.wrap preserves the assembled terminal');
      expect(session.terminal, same(assembly.terminal),
          reason: 'the session and assembly use the same output');
    });

    test('wrap keeps the terminal an assembly was already given', () {
      final handed = CaptureTerminal();
      final assembly = TuiAssembly.start(
        providerFactory: (_) => ScriptedProvider(const []),
        terminal: handed,
        options: AssemblyOptions(
            configPath: '/nonexistent/tina/config', workingDirectory: ws.path),
      );
      final session = TuiSession.wrap(assembly);
      expect(session.terminal, same(handed),
          reason: 'a headless build keeps its own terminal');
    });

    test('the selected channel fails closed before its frontend attaches',
        () async {
      final session = TuiSession.start(
          configPath: '/nonexistent/tina/config',
          providerFactory: (_) => ScriptedProvider(const []),
          workingDirectory: ws.path);
      addTearDown(session.close);
      expect(session.host.config.plugins.whereType<ApprovalTuiPlugin>(),
          hasLength(1));
      await expectLater(
          session.assembly.tools.sandbox.approver!(
              (op: FileOp.write, path: '/tmp/tina_app_test_probe'), 'outside'),
          throwsA(isA<SandboxViolation>()));
    });
  });

  group('the render loop, driven through fake bytes', () {
    test('a full turn: line in, reply in the chat, /quit out', () async {
      final io = FakeIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) =>
            ScriptedProvider([scriptedReply('the model answered')]),
        workingDirectory: ws.path,
      );
      final done = runApp(
        session,
        screen: fakeScreen(io),
        consoleContextFor: scriptedConsole(NoKeys.new),
      );
      // Let the loop arm its readLine, then speak and quit.
      expect(io.written.toString(), contains('mode: ask'),
          reason: 'the mode strip must be visible at 80 columns');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('hello tina\r'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
      expect(session.assembly.quitRequested, isTrue);
      // Model output is painted from deltas/the log; plugin lines use Terminal.
      expect(io.written.toString(), contains('the model answered'));
    });

    test('a resumed log is painted by the first frame', () async {
      // Session one: one turn, persisted.
      final storePath = '${ws.path}/store.db';
      final one = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) =>
            ScriptedProvider([scriptedReply('remembered answer')]),
        workingDirectory: ws.path,
        storePath: storePath,
      );
      await one.runLine('persist this');
      one.close();

      // Session two resumes the same log through the app: the first
      // paint replays the input as `you: …`.
      final io2 = FakeIo();
      final two = TuiAssembly.start(
        providerFactory: (_) => ScriptedProvider([scriptedReply('again')]),
        options: AssemblyOptions(
          configPath: '/nonexistent/tina/config',
          workingDirectory: ws.path,
          storePath: storePath,
          sessionId: one.host.session.id,
        ),
      );
      final session2 = TuiSession.wrap(two);
      final done2 = runApp(
        session2,
        screen: fakeScreen(io2),
        consoleContextFor: scriptedConsole(NoKeys.new),
      );
      await feedWhen(io2, '/quit', () => Future<bool>.value(true));
      expect(await done2, 0);
      // The first-paint replay goes straight into the chat region —
      // it is the app's render of the log, not a plugin tell — so the
      // evidence is in what the screen emitted.
      expect(io2.written.toString(), contains('persist this'),
          reason: 'the resumed input was painted by the first frame');
    });
  });

  group('the approval question: three answers through the loop', () {
    test('real editor keys paint the accepted selection and ignore text',
        () async {
      final io = FakeIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => ScriptedProvider(const []),
        workingDirectory: ws.path,
      );
      final done = runApp(session, screen: fakeScreen(io));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final approval = session.assembly.tools.sandbox.approver!(
        (op: FileOp.write, path: '${ws.parent.path}/outside.txt'),
        'outside the project root',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('x'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(approvalUi(session).asker!.current, isNotNull,
          reason: 'an unrelated key must not close the approval');
      io.feedBytes('\x1b[A'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(approvalUi(session).asker!.currentDialog!.current.decision,
          ApprovalDecision.allow);
      final latestPaint = io.written.toString();
      expect(latestPaint, contains('❯ [y] allow once'),
          reason: 'the painted selection follows the deciding dialog');
      io.feedBytes('\r'.codeUnits);
      expect(await approval.timeout(const Duration(seconds: 2)), Approval.yes);
      expect(approvalUi(session).asker!.currentDialog, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done.timeout(const Duration(seconds: 2)), 0);
    });

    /// The provider script every answer-test runs: one out-of-workspace
    /// write, then the acknowledgement turn.
    ScriptedProvider outsideWrite() => ScriptedProvider([
          scriptedReply('', calls: [
            ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {
                'filePath': '/tmp/tina_app_outside_probe',
                'content': 'x',
              },
            ),
          ]),
          scriptedReply('acknowledged'),
        ]);

    void cleanup() {
      try {
        File('/tmp/tina_app_outside_probe').deleteSync();
      } catch (_) {}
    }

    test('yes proceeds: the file exists, the question came first', () async {
      final io = FakeIo();
      final approvals = <String>[];
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => outsideWrite(),
        workingDirectory: ws.path,
      );
      final done = runApp(
        session,
        screen: fakeScreen(io),
        consoleContextFor: scriptedConsole(
            () => ScriptedKeySource(const [ApprovalKey.confirm])),
      );
      // The loop wired the dialog asker; the observer rides on it.
      final asker = approvalUi(session).asker!;
      asker.onChange = () {
        final a = asker.current;
        if (a != null) approvals.add('${a.operation}:${a.target}');
      };
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('do the write\r'.codeUnits);
      // The question opens mid-turn; the scripted key source answers
      // it as soon as the asker calls. Then quit the app.
      await feedWhen(io, '/quit',
          () => Future<bool>.value(session.host.session.turns.length >= 2));
      expect(await done, 0);
      expect(approvals, hasLength(1),
          reason: 'the question was asked — not a refusal');
      expect(approvals.single, contains('/tmp/tina_app_outside_probe'));
      expect(File('/tmp/tina_app_outside_probe').existsSync(), isTrue,
          reason: 'yes proceeded');
      cleanup();
    });

    test('no refuses: the model reads the refusal as an error result',
        () async {
      final io = FakeIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => outsideWrite(),
        workingDirectory: ws.path,
      );
      final done = runApp(
        session,
        screen: fakeScreen(io),
        consoleContextFor: scriptedConsole(
            () => ScriptedKeySource(const [ApprovalKey.cancel])),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('do the write\r'.codeUnits);
      await feedWhen(io, '/quit',
          () => Future<bool>.value(session.host.session.turns.length >= 2));
      expect(await done, 0);
      // The refusal reached the model as that call's tool result: the
      // acknowledgement turn's request carries the error block.
      final request = session.host.session.turns.last;
      final userMessage =
          request.messages.where((m) => m.role == Role.user).last;
      final block = userMessage.content.whereType<ToolResultBlock>().single;
      expect(block.isError, isTrue);
      expect(block.content, contains('denied'));
      expect(File('/tmp/tina_app_outside_probe').existsSync(), isFalse);
      cleanup();
    });

    test('always is answered once and remembered for the second ask', () async {
      final io = FakeIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => ScriptedProvider([
          scriptedReply('', calls: [
            ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {
                'filePath': '/tmp/tina_app_always_probe',
                'content': 'one',
              },
            ),
            ToolUseBlock(
              id: 'c2',
              name: 'write',
              input: {
                'filePath': '/tmp/tina_app_always_probe',
                'content': 'two',
              },
            ),
          ]),
          scriptedReply('both acknowledged'),
        ]),
        workingDirectory: ws.path,
      );
      final done = runApp(
        session,
        screen: fakeScreen(io),
        consoleContextFor: scriptedConsole(
            () => ScriptedKeySource(const [ApprovalKey.always])),
      );
      final asker = approvalUi(session).asker!;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('write both\r'.codeUnits);
      await feedWhen(io, '/quit',
          () => Future<bool>.value(session.host.session.turns.length >= 2));
      expect(await done, 0);
      // The explicit always shortcut selects the remembered grant; the sandbox remembers
      // the grant, so the second identical write never asked.
      expect(asker.current, isNull, reason: 'no question left on the screen');
      expect(File('/tmp/tina_app_always_probe').readAsStringSync(), 'two',
          reason: 'both writes ran, the second after the first');
    });
  });
}

ApprovalTuiPlugin approvalUi(TuiSession session) =>
    session.host.config.plugins.whereType<ApprovalTuiPlugin>().single;

ConsoleContext Function(Screen, LineEditor) scriptedConsole(
        KeySource Function() keys) =>
    (screen, editor) {
      Future<void>? active;
      KeySource? source;
      return ConsoleContext(
          screen: screen,
          editor: editor,
          readKey: (cancelled) async {
            if (!identical(active, cancelled)) {
              active = cancelled;
              source = keys();
            }
            final key = await source!.next();
            return switch (key) {
              ApprovalKey.allow => CharInput('y'),
              ApprovalKey.deny => CharInput('n'),
              ApprovalKey.always => CharInput('a'),
              ApprovalKey.toggleReadDirectory => CharInput('r'),
              ApprovalKey.pageUp => ArrowKey(ArrowDirection.pageUp),
              ApprovalKey.pageDown => ArrowKey(ArrowDirection.pageDown),
              ApprovalKey.scrollUp => ScrollEvent(up: true),
              ApprovalKey.scrollDown => ScrollEvent(up: false),
              ApprovalKey.up => ArrowKey(ArrowDirection.up),
              ApprovalKey.down => ArrowKey(ArrowDirection.down),
              ApprovalKey.confirm => ControlKey(ControlCode.enter),
              ApprovalKey.cancel => EscapeKey(),
              ApprovalKey.details => ControlKey(ControlCode.tab),
              null => null,
            };
          });
    };
