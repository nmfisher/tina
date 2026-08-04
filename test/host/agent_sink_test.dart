import 'package:tina_engine/tina_engine.dart';
import 'package:tina/chat_agent_sink.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// Build a [ChatAgentSink] over a passthrough screen, returning the buffer it
/// writes to so assertions can inspect the exact bytes. [ansi] defaults to
/// [AnsiCapable.no] so writes are verbatim; pass [AnsiCapable.yes] to assert
/// on color routing.
({ChatAgentSink sink, String Function() written}) _sink(
    {AnsiCapable ansi = AnsiCapable.no}) {
  final io = FakeStdio();
  final screen = Screen.passthrough(io, ansi: ansi);
  return (
    sink: ChatAgentSink(screen.chat, Spinner(enabled: false)),
    written: () => io.written.toString(),
  );
}

void main() {
  group('ChatAgentSink', () {
    test('text writes through verbatim', () {
      final w = _sink();
      w.sink.text('hello');
      expect(w.written(), 'hello');
    });

    test('text emits the agent style in TUI mode (policy at the sink)', () {
      // Non-passthrough screen with color on: the sink's policy picks
      // the agent style code and the region renders it as default-fg text
      // (no background bar). Pins the styling policy at its new home.
      final io = FakeStdio()..columns = 100;
      final screen =
          Screen(io: io, layout: ScreenLayout.fromSize(100, 24), ansi: AnsiCapable.yes);
      screen.redrawFrame();
      io.written.clear();

      final sink = ChatAgentSink(screen.chat, Spinner(enabled: false));
      sink.text('hello\n');

      final out = io.written.toString();
      expect(out, contains('\x1b[39mhello\x1b[0m'),
          reason: 'agent prose must render as default-fg styled text');
      expect(out, isNot(contains('\x1b[30;47m')),
          reason: 'agent prose must not get a background bar');
    });

    test('newline', () {
      final w = _sink();
      w.sink.newline();
      expect(w.written(), '\n');
    });

    test('toolStart renders the arrow + described bash command', () {
      final w = _sink();
      w.sink
          .toolStart(const ToolStartEvent('bash', 'u1', {'command': 'ls -la'}));
      expect(w.written(), '→ bash: ls -la\n');
    });

    test('toolStart falls back to the bare tool name for unknown shapes', () {
      final w = _sink();
      w.sink.toolStart(const ToolStartEvent('glob', 'u2', {'pattern': '**'}));
      expect(w.written(), '→ glob\n');
    });

    test('toolStart truncates long bash commands at 80 chars', () {
      final w = _sink();
      w.sink.toolStart(ToolStartEvent('bash', 'u3', {'command': 'x' * 100}));
      expect(w.written(), '→ bash: ${'x' * 80}…\n');
    });

    test('toolComplete success', () {
      final w = _sink();
      w.sink.toolComplete(
          const ToolCompleteEvent('bash', 'u1', isError: false, result: 'r'));
      expect(w.written(), '  ok\n');
    });

    test('toolComplete error truncates the result at 200 chars', () {
      final w = _sink();
      w.sink.toolComplete(ToolCompleteEvent(
          'bash', 'u1', isError: true, result: 'x' * 300));
      expect(w.written(), '  failed: ${'x' * 200}…\n');
    });

    test('toolOutput routes stdout→dim and stderr→red under color', () {
      final w = _sink(ansi: AnsiCapable.yes);
      w.sink.toolOutput(const ToolOutputEvent('bash', 'u1', 'out'));
      w.sink.toolOutput(
          const ToolOutputEvent('bash', 'u1', 'err', stderr: true));
      expect(w.written(), '\x1b[2mout\x1b[0m\x1b[31merr\x1b[0m');
    });

    test('notice kind routes to dim / yellow / red under color', () {
      final w = _sink(ansi: AnsiCapable.yes);
      w.sink.notice('info');
      w.sink.notice('warn', kind: NoticeKind.warning);
      w.sink.notice('boom', kind: NoticeKind.error);
      expect(w.written(), '\x1b[2minfo\x1b[0m\x1b[33mwarn\x1b[0m\x1b[31mboom\x1b[0m');
    });

    test('activity start/stop are inert (spinner is a no-op)', () {
      final w = _sink();
      w.sink.activityStart();
      w.sink.activityStop();
      expect(w.written(), '');
    });
  });
}
