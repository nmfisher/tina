import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina/chat/chat_renderer.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/chat/markdown_renderer.dart';
import 'package:tina/composition/chat_renderer.dart';
import 'package:tina/composition/timestamp_chat.dart';
import 'package:tina/frontend/renderers.dart';
import 'package:tina_engine/tina_engine.dart';

const _stamp = '03:04:05 ';

const _speaker = ChatSpeaker(id: 'c1', label: 'main');

ChatBlock _prose({String text = 'hello'}) => ChatBlock.prose(
      _speaker,
      [MarkdownLine(runs: [MarkdownRun(text, null)])],
    );

/// Two paragraphs, so `renderTranscript` emits a blank separator line.
ChatBlock _twoParagraphs() => ChatBlock.prose(
      _speaker,
      [
        MarkdownLine(runs: [MarkdownRun('first', null)]),
        const MarkdownLine.blank(),
        MarkdownLine(runs: [MarkdownRun('second', null)]),
      ],
    );

RenderContext _ctx(int width) =>
    RenderContext(width: width, theme: const Theme.defaults());

List<RenderLine> _render(
  PluginRuntime runtime,
  ChatBlock block,
  int width,
) =>
    Renderers(runtime.scope).render(
      block,
      _ctx(width),
      fallback: const ChatRenderer(),
    );

String _text(RenderLine line) => line.runs.map((r) => r.text).join();

PluginRuntime _runtime({required DateTime Function() now}) {
  final runtime = PluginRuntime(
    name: 'timestamp-chat-test',
    plugins: [
      timestampChatPlugin(now: now),
      chatRendererPlugin(),
    ],
  )..activateSync();
  addTearDown(runtime.dispose);
  return runtime;
}

void main() {
  test('stamps every non-blank line and keeps the default content', () {
    final runtime = _runtime(now: () => DateTime(2026, 1, 2, 3, 4, 5));

    final lines = _render(runtime, _prose(), 40);
    expect(lines, isNotEmpty);
    for (final line in lines.where((l) => !l.isBlank)) {
      expect(_text(line), startsWith(_stamp));
      expect(_text(line), contains('hello'));
    }
  });

  test('delegating to the built-in keeps its row styles, only adding the gutter',
      () {
    final runtime = _runtime(now: () => DateTime(2026, 1, 2, 3, 4, 5));

    final lines = _render(runtime, _prose(), 40);
    final bare = const ChatRenderer().render(_prose(), _ctx(40 - 9));
    expect(lines.length, bare.length);
    for (var i = 0; i < lines.length; i++) {
      expect(lines[i].bar, bare[i].bar);
      expect(_text(lines[i]).substring(_stamp.length), _text(bare[i]));
    }
  });

  test('the stamp is stable across repaints and widths (no drift)', () {
    var clock = DateTime(2026, 1, 2, 3, 4, 5);
    final runtime = _runtime(now: () => clock);
    final block = _prose();

    final first = _render(runtime, block, 40);
    expect(_text(first.first), startsWith(_stamp));

    // Repaint after time passes — a resize, fold or status update — must not
    // rewrite the block's time.
    clock = DateTime(2026, 1, 2, 9, 9, 9);
    final repainted = _render(runtime, block, 60);
    expect(_text(repainted.first), startsWith(_stamp),
        reason: 'first-seen time must be memoized per block instance');
  });

  test('a new block is stamped with the current time', () {
    var clock = DateTime(2026, 1, 2, 3, 4, 5);
    final runtime = _runtime(now: () => clock);

    _render(runtime, _prose(text: 'one'), 40);
    clock = DateTime(2026, 1, 2, 9, 9, 9);
    final lines = _render(runtime, _prose(text: 'two'), 40);

    expect(_text(lines.first), startsWith('09:09:09 '),
        reason: 'each block records its own first render, not one global time');
  });

  test('every painted line fits the requested width', () {
    final runtime = _runtime(now: () => DateTime(2026, 1, 2, 3, 4, 5));

    for (final width in [24, 40, 80]) {
      final lines = _render(
        runtime,
        _prose(text: 'wrapping words aaaaaaaaaaaaaaaaaaaaaaaa end'),
        width,
      );
      for (final line in lines) {
        expect(plainWidth(_text(line)), lessThanOrEqualTo(width),
            reason: 'renderers own their fit at width $width');
      }
    }
  });

  test('blank separator lines stay blank', () {
    final runtime = _runtime(now: () => DateTime(2026, 1, 2, 3, 4, 5));

    final lines = _render(runtime, _twoParagraphs(), 40);
    expect(lines.where((l) => l.isBlank), isNotEmpty);
    for (final line in lines.where((l) => l.isBlank)) {
      expect(line.runs, isEmpty);
    }
    final stamped = lines.where((l) => !l.isBlank).toList();
    expect(stamped.length, 2, reason: 'one stamp row per paragraph');
    for (final line in stamped) {
      expect(_text(line), startsWith(_stamp));
    }
  });

  test('a width too narrow for the gutter degrades without overflowing', () {
    final runtime = _runtime(now: () => DateTime(2026, 1, 2, 3, 4, 5));

    final lines = _render(runtime, _prose(), 10);
    expect(lines, isNotEmpty);
    for (final line in lines) {
      expect(plainWidth(_text(line)), lessThanOrEqualTo(10));
    }
    expect(_text(lines.first), contains('hello'));
  });
}
