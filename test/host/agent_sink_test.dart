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

/// Build a [ChatAgentSink] over a real (non-passthrough) screen so the
/// markdown path runs. Bytes are captured after the initial frame paint.
({ChatAgentSink sink, String Function() written}) _tuiSink(
    {AnsiCapable ansi = AnsiCapable.yes,
    void Function(String text)? onRawText}) {
  final io = FakeStdio()..columns = 100;
  final screen =
      Screen(io: io, layout: ScreenLayout.fromSize(100, 24), ansi: ansi);
  screen.redrawFrame();
  io.written.clear();
  return (
    sink: ChatAgentSink(screen.chat, Spinner(enabled: false),
        onRawText: onRawText),
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
      final w = _tuiSink();
      w.sink.text('hello\n');
      w.sink.newline(); // prose end: flush the held paragraph

      final out = w.written();
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

    test('toolStart shows the glob pattern', () {
      final w = _sink();
      w.sink.toolStart(const ToolStartEvent('glob', 'u2', {'pattern': '**'}));
      expect(w.written(), '→ glob: **\n');
    });

    test('toolStart shows the glob pattern and path when given', () {
      final w = _sink();
      w.sink.toolStart(
          const ToolStartEvent('glob', 'u2', {'pattern': '*.dart', 'path': '/a'}));
      expect(w.written(), '→ glob: *.dart in /a\n');
    });

    test('toolStart shows the grep pattern', () {
      final w = _sink();
      w.sink.toolStart(const ToolStartEvent('grep', 'g1', {'pattern': 'TODO'}));
      expect(w.written(), '→ grep: TODO\n');
    });

    test('toolStart shows the grep pattern and path when given', () {
      final w = _sink();
      w.sink.toolStart(
          const ToolStartEvent('grep', 'g2', {'pattern': 'TODO', 'path': '/b'}));
      expect(w.written(), '→ grep: TODO in /b\n');
    });

    test('toolStart shows the search symbol', () {
      final w = _sink();
      w.sink
          .toolStart(const ToolStartEvent('search', 's1', {'symbol': 'Agent'}));
      expect(w.written(), '→ search: Agent\n');
    });

    test('toolStart summarizes unknown tool input as key=value pairs', () {
      final w = _sink();
      w.sink.toolStart(const ToolStartEvent(
          'collect', 'c1', {'scope': 'docs', 'depth': 3}));
      expect(w.written(), '→ collect: scope=docs depth=3\n');
    });

    test('toolStart truncates unknown tool summaries head+tail at 80', () {
      final w = _sink();
      // joined summary is 'x=' + 200 a's (202 chars); kept as its first 52
      // chars ('x=' + 50 a's), an ellipsis, and its last 27 a's — 80 total.
      w.sink.toolStart(ToolStartEvent('collect', 'c2', {'x': 'a' * 200}));
      expect(w.written(), '→ collect: x=${'a' * 50}…${'a' * 27}\n');
    });

    test('toolStart shows the bare name when input is empty', () {
      final w = _sink();
      w.sink.toolStart(const ToolStartEvent('collect', 'c3', {}));
      expect(w.written(), '→ collect\n');
    });

    test('toolStart truncates long bash commands head+tail at 80 chars', () {
      final w = _sink();
      // 100 x's: kept as the first 52, an ellipsis, and the last 27 — 80
      // total. The tail is what an approver needs (a `| sh`, a redirect).
      w.sink.toolStart(ToolStartEvent('bash', 'u3', {'command': 'x' * 100}));
      expect(w.written(), '→ bash: ${'x' * 52}…${'x' * 27}\n');
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
      // #50: a result past the 200-char render gains a dim /output pointer
      // line after the truncated failed line.
      expect(w.written(),
          '  failed: ${'x' * 200}…\n  … (/output for the full error)\n');
    });

    test('toolComplete error fires onCapped with the full result', () {
      final capped = <CappedToolOutput>[];
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.no);
      final sink =
          ChatAgentSink(screen.chat, Spinner(enabled: false), onCapped: capped.add);
      final result = 'E' * 250 + 'TAIL';

      sink.toolStart(const ToolStartEvent('bash', 'u1', {'command': 'go'}));
      sink.toolComplete(ToolCompleteEvent('bash', 'u1',
          isError: true, result: result));

      // The failed render cut the result: the ring must carry the full text,
      // not the 200-char window the chat printed.
      expect(capped, hasLength(1));
      expect(capped.single.text, result);
      expect(capped.single.toolName, 'bash');
      expect(capped.single.input, {'command': 'go'});
      expect(capped.single.hiddenChars, 54); // 254 - 200 printed chars
    });

    test('toolComplete error keeps a short result verbatim, no ring', () {
      final capped = <CappedToolOutput>[];
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.no);
      final sink =
          ChatAgentSink(screen.chat, Spinner(enabled: false), onCapped: capped.add);

      sink.toolComplete(const ToolCompleteEvent('bash', 'u1',
          isError: true, result: 'boom'));

      expect(io.written.toString(), '  failed: boom\n');
      expect(capped, isEmpty);
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

  group('ChatAgentSink — streamed markdown (tin-g7rk)', () {
    test('passthrough keeps markdown markers verbatim', () {
      final w = _sink();
      w.sink.text('**not bold** `code`\n');
      w.sink.newline();
      expect(w.written(), '**not bold** `code`\n\n');
    });

    test('an open paragraph is held back until prose ends', () {
      final w = _tuiSink();
      w.sink.text('hel');
      w.sink.text('lo\n'); // complete line, but no blank line: still open
      expect(w.written(), '',
          reason: 'an unterminated block must not render piecemeal');
      w.sink.newline();
      expect(w.written(), contains('hello'));
    });

    test('a blank line closes the block mid-stream', () {
      final w = _tuiSink();
      w.sink.text('para one\n\n');
      expect(w.written(), contains('para one'));
    });

    test('a fenced code block renders with the bar style', () {
      final w = _tuiSink();
      w.sink.text('```\nint x = 1;\n```\n');
      final out = w.written();
      expect(out, contains('int x = 1;'));
      expect(out, contains('\x1b[100m'),
          reason: 'code lines carry the theme codeBlock bar (grey bg)');
    });

    test('inline markers render as SGR, not literal', () {
      final w = _tuiSink();
      w.sink.text('run **bold** now\n\n');
      final out = w.written();
      expect(out, contains('\x1b[1mbold\x1b[0m'));
      expect(out, isNot(contains('**')));
    });

    test('consecutive blocks are separated by exactly one blank line', () {
      final w = _tuiSink(ansi: AnsiCapable.no);
      w.sink.text('one\n\n');
      final first = w.written().length;
      w.sink.text('two\n\n');
      final out = w.written().substring(first);
      // One blank row between the blocks, then the second block's text.
      expect(out, contains('two'));
      expect(out, isNot(contains('two\n\n\ntwo')),
          reason: 'no double blank between streamed blocks');
    });

    test('no-color surfaces render structure without SGR styling', () {
      final w = _tuiSink(ansi: AnsiCapable.no);
      w.sink.text('- item\n\n');
      final out = w.written();
      expect(out, contains('• item')); // structure survives without color
      expect(out, isNot(contains('\x1b[39m')));
      expect(out, isNot(contains('\x1b[100m')));
    });

    test('toolStart flushes held prose before the tool line', () {
      final w = _tuiSink(ansi: AnsiCapable.no);
      w.sink.text('about to list\n'); // held: no blank line yet
      w.sink.toolStart(const ToolStartEvent('bash', 'u1', {'command': 'ls'}));
      final out = w.written();
      expect(out, contains('about to list'));
      expect(out.indexOf('about to list'), lessThan(out.indexOf('→ bash')));
    });

    test('notice flushes held prose', () {
      final w = _tuiSink(ansi: AnsiCapable.no);
      w.sink.text('half a thought\n');
      w.sink.notice('[cancelled]\n');
      expect(w.written(), contains('half a thought'));
    });

    test('onRawText receives the turn raw, verbatim and cumulative', () {
      final raw = <String>[];
      final w = _tuiSink(onRawText: raw.add);
      w.sink.text('**a**\n\n');
      w.sink.text('b\n\n');
      expect(raw, ['**a**\n\n', '**a**\n\nb\n\n'],
          reason: 'each closed segment re-fires with the whole turn so far');
      w.sink.beginAssistantTurn();
      w.sink.text('c\n\n');
      expect(raw.last, 'c\n\n', reason: 'a new turn drops the old raw');
    });

    test('beginAssistantTurn abandons an unclosed block', () {
      final w = _tuiSink(ansi: AnsiCapable.no);
      w.sink.text('canceled mid-str'); // no newline: held
      w.sink.beginAssistantTurn();
      w.sink.text('fresh\n\n');
      final out = w.written();
      expect(out, contains('fresh'));
      expect(out, isNot(contains('canceled')),
          reason: 'the abandoned block must not leak into the new turn');
    });
  });
}
