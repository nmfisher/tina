// The TUI session wrapper: the assembly's wiring with the TUI terminal
// in the slot. A scripted provider drives a full turn; the dispatch
// refuses an unknown /word through the terminal, never as a turn; /quit
// flags the loop to stop; /mode flips the assembly's mode service — the
// mode enum never appears in this package's logic.
//
// Run: dart test
library;

import 'dart:io';
import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart' show AnsiBackend;
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart' show ModePlugin;
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo;

void main() {
  late Directory ws;
  late TuiSession tui;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_tui_session_');
    tui = TuiSession.start(
      configPath: '/nonexistent/tina/config',
      providerFactory: (_) => ScriptedProvider([scriptedReply('echo reply')]),
      workingDirectory: ws.path,
    );
  });
  tearDown(() {
    tui.close();
    ws.deleteSync(recursive: true);
  });

  test('a full turn through the assembly\u2019s host, echoed to the terminal',
      () async {
    await tui.runLine('hello');
    expect(tui.host.session.lastReply, 'echo reply');
    expect((tui.terminal as TuiTerminal).lines.map((l) => l.text).join("\n"),
        contains('echo reply'));
    expect(tui.host.session.loop.log.length, greaterThanOrEqualTo(3),
        reason: 'input, response, stop — the same log a headless run keeps');
  });

  test('an unknown /word is refused through the terminal, no turn', () async {
    await tui.runLine('/frobnicate');
    expect((tui.terminal as TuiTerminal).lines.map((l) => l.text).join("\n"),
        contains('unknown command: /frobnicate'));
    expect(tui.host.session.loop.log, isEmpty,
        reason: 'the refusal is not a turn');
  });

  test('manual shell output is captured without a model turn or tool approval',
      () async {
    await tui.runLine('/mode read-only');
    final before = tui.host.session.loop.log.toList();
    await tui
        .runLine('!printf "manual stdout"; printf "manual stderr" >&2; exit 7');
    final output =
        (tui.terminal as TuiTerminal).lines.map((l) => l.text).join('\n');
    expect(output, contains('manual stdout'));
    expect(output, contains('manual stderr'));
    expect(output, contains('exit code: 7'));
    expect(tui.host.session.loop.log, before,
        reason: 'manual execution never enters the model loop');
    expect(tui.host.session.lastReply, isNull);
    expect(tui.canCancel, isFalse);
  }, skip: Platform.isWindows);

  test('/context opens immediately during a busy model turn', () async {
    final config = File('${ws.path}/context-config')
      ..writeAsStringSync(
          '[default]\nmodel="scripted"\n[plugins]\nenabled=["tina/context", "tina/context-tui"]\n'
          '[plugin_config."tina/context"]\nbudget_tokens=16000\nresponse_reserve_tokens=1024\n');
    final ready = Completer<void>();
    final release = Completer<void>();
    final provider = _WaitingProvider(ready, release);
    final session = TuiSession.start(
        configPath: config.path,
        providerFactory: (_) => provider,
        workingDirectory: ws.path);
    final io = FakeIo();
    final screen = Screen.withBackend(
        io: io,
        backend: AnsiBackend(io: io, ansi: AnsiCapable.yes),
        layout: ScreenLayout.fromSize(100, 24, split: false));
    final editor = LineEditor(screen: screen);
    final viewer = session.host.plugins.whereType<ContextTuiPlugin>().single;
    viewer.attachConsole(ConsoleContext(screen: screen, editor: editor));
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      session.close();
      editor.close(reportLatency: false);
      screen.dispose();
      io.closeInput();
    });
    final turn = session.runLine('normal message');
    await ready.future;
    final command = session.offerCommand('/context');
    expect(command, isNotNull);
    await command!.timeout(const Duration(seconds: 3));
    expect(viewer.isOpen, isTrue);
    expect(viewer.visibleLines.join('\n'), contains('normal message'));
    expect(viewer.visibleLines.join('\n'), contains('/ 15.0k input budget'));
    expect(viewer.visibleLines.join('\n'), contains('last prepared request'));
    expect(release.isCompleted, isFalse);
    expect(session.host.session.loop.pendingInputCount, 0);
    release.complete();
    await turn;
    expect(provider.calls, 1);
  });

  test('manual shell commands do not enter a busy model input queue', () async {
    final ready = Completer<void>();
    final release = Completer<void>();
    final provider = _WaitingProvider(ready, release);
    final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => provider,
        workingDirectory: ws.path);
    addTearDown(session.close);
    final turn = session.runLine('normal message');
    await ready.future;
    expect(session.offerInput('!echo local'), isFalse);
    expect(session.offerInput('/shell echo local'), isFalse);
    expect(session.host.session.loop.pendingInputCount, 0);
    release.complete();
    await turn;
    expect(provider.calls, 1);
  });

  for (final prefix in ['!', '/shell ']) {
    test('$prefix runs immediately during a busy model turn', () async {
      final ready = Completer<void>();
      final release = Completer<void>();
      final provider = _WaitingProvider(ready, release);
      final session = TuiSession.start(
          configPath: '/nonexistent/tina/config',
          providerFactory: (_) => provider,
          workingDirectory: ws.path);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        session.close();
      });
      final turn = session.runLine('normal message');
      await ready.future;
      final shell = session.offerCommand('${prefix}echo immediate > executed');
      expect(shell, isNotNull);
      await shell!.timeout(const Duration(seconds: 3));
      expect(
          File('${ws.path}/executed').readAsStringSync().trim(), 'immediate');
      expect(release.isCompleted, isFalse,
          reason: 'the shell finishes before the model turn is released');
      expect(session.host.session.loop.pendingInputCount, 0);
      expect(provider.calls, 1);
      release.complete();
      await turn;
    }, skip: Platform.isWindows);
  }

  test('an immediate shell remains cancellable after the model turn finishes',
      () async {
    final ready = Completer<void>();
    final release = Completer<void>();
    final provider = _WaitingProvider(ready, release);
    final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => provider,
        workingDirectory: ws.path);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      session.close();
    });
    final turn = session.runLine('normal message');
    await ready.future;
    final shell = session
        .offerCommand('!echo ready > started; while :; do sleep 0.05; done');
    expect(shell, isNotNull);
    final started = File('${ws.path}/started');
    final deadline = Stopwatch()..start();
    while (!started.existsSync() &&
        deadline.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started.existsSync(), isTrue);
    await session.offerCommand('/shell echo duplicate > duplicate');
    expect(File('${ws.path}/duplicate').existsSync(), isFalse);
    expect((session.terminal as TuiTerminal).lines.map((l) => l.text),
        contains('A shell command is already running in this session.'));
    release.complete();
    await turn;
    expect(session.canCancel, isTrue,
        reason: 'finishing another command or turn must not lose the shell');
    session.cancel();
    await shell!.timeout(const Duration(seconds: 3));
    expect(session.canCancel, isFalse);
    expect(
        (session.terminal as TuiTerminal).lines.map((l) => l.text).join('\n'),
        contains('cancelled: command stopped'));
    expect(provider.calls, 1);
    await session.runLine('next message');
    expect(provider.calls, 2,
        reason: 'cancelling the shell must not cancel the next model turn');
  }, skip: Platform.isWindows);

  test('update runs immediately during a busy model turn', () async {
    final ready = Completer<void>();
    final release = Completer<void>();
    final provider = _WaitingProvider(ready, release);
    final session = TuiSession.start(
        configPath: '${ws.path}/config',
        providerFactory: (_) => provider,
        workingDirectory: ws.path);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      session.close();
    });
    final turn = session.runLine('normal message');
    await ready.future;
    final update = session.offerCommand('/update unknown');
    expect(update, isNotNull, reason: 'update runs without entering the queue');
    await update;
    expect(
        (session.terminal as TuiTerminal)
            .lines
            .map((line) => line.text)
            .join('\n'),
        contains('usage: /update'));
    expect(provider.calls, 1);
    expect(release.isCompleted, isFalse);
    release.complete();
    await turn;
  });

  test('session cancellation reaches the active manual shell command',
      () async {
    final pending =
        tui.runLine('!echo ready > started; while :; do sleep 0.05; done');
    final started = File('${ws.path}/started');
    final deadline = Stopwatch()..start();
    while (!started.existsSync() &&
        deadline.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started.existsSync(), isTrue);
    expect(tui.canCancel, isTrue);
    tui.cancel();
    await pending.timeout(const Duration(seconds: 3));
    expect(tui.canCancel, isFalse);
    expect((tui.terminal as TuiTerminal).lines.map((l) => l.text).join('\n'),
        contains('cancelled: command stopped'));
    expect(tui.host.session.loop.log, isEmpty);
  }, skip: Platform.isWindows);

  test('/quit flags the loop to stop', () async {
    expect(await tui.runLine('/quit'), isTrue);
    expect(tui.assembly.quitRequested, isTrue);
  });

  test('command dispatch waits for asynchronous work', () async {
    final release = Completer<void>();
    var finished = false;
    tui.commands.publish(Command(
      name: 'wait',
      description: 'wait for completion',
      handler: (_) => release.future,
    ));
    final pending = tui.runLine('/wait').then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    release.complete();
    await pending;
    expect(finished, isTrue);
    expect(tui.host.session.loop.log, isEmpty);
  });

  test('an empty line is no turn and no output', () async {
    final before = tui.host.session.loop.log.length;
    await tui.runLine('   ');
    expect(tui.host.session.loop.log.length, before);
    expect((tui.terminal as TuiTerminal).lines.map((l) => l.text).join("\n"),
        isEmpty);
  });

  test('/mode flips the assembly\u2019s mode service by word', () async {
    await tui.runLine('/mode read-only');
    expect(ModePlugin.wordFor(tui.assembly.tools.mode), 'read-only');
    expect((tui.terminal as TuiTerminal).lines.map((l) => l.text).join("\n"),
        contains('mode: read-only'));
    // And back, by the same word.
    await tui.runLine('/mode ask');
    expect(ModePlugin.wordFor(tui.assembly.tools.mode), 'ask');
  });

  test('a handed-in terminal is used; a default one is built otherwise', () {
    final handed = TuiTerminal();
    final t = TuiSession.start(
      configPath: '/nonexistent/tina/config',
      providerFactory: (_) => ScriptedProvider(const []),
      workingDirectory: ws.path,
      terminal: handed,
    );
    expect(t.terminal, same(handed));
    t.close();

    final fresh = TuiSession.start(
      configPath: '/nonexistent/tina/config',
      providerFactory: (_) => ScriptedProvider(const []),
      workingDirectory: ws.path,
    );
    expect(fresh.terminal, isNot(same(handed)));
    fresh.close();
  });
}

final class _WaitingProvider extends LlmProvider {
  _WaitingProvider(this.ready, this.release) : super('waiting');
  final Completer<void> ready, release;
  int calls = 0;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    calls++;
    if (!ready.isCompleted) ready.complete();
    await release.future;
    yield* Stream.fromIterable(scriptedReply('done'));
  }
}
