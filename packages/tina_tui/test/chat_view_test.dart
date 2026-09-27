import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_tui/tina_tui.dart';

/// Headless: pure value-to-rows rendering, no terminal.
void main() {
  const view = ChatView();

  test('a message with text and tool blocks renders the expected rows', () {
    final message = Message(
      role: Role.assistant,
      content: [
        const TextBlock('Reading the config first.'),
        const ToolUseBlock(
          id: 'c1',
          name: 'read',
          input: {'path': '/etc/tina.conf'},
        ),
        const ToolResultBlock(toolUseId: 'c1', content: 'port=4242'),
      ],
    );
    final rows = view.render(message, width: 80);

    // Row 1: the prose, default style.
    expect(rows[0].runs.single.text, 'Reading the config first.');
    expect(rows[0].runs.single.code, isNull);

    // Row 2: the chip, green because a result was recorded.
    expect(rows[1].runs.first.text, '⏺ read');
    expect(rows[1].runs.first.code, Theme.defaults().chat.green);
    expect(rows[1].runs.last.text, contains('path: "/etc/tina.conf"'));

    // Row 3: the result's first line, dim, under the chip.
    expect(rows[2].runs.single.text, '  ↳ port=4242');
    expect(rows[2].runs.single.code, Theme.defaults().chat.dim);
    expect(rows, hasLength(3));
  });

  test('a tool result with isError renders the chip red', () {
    final message = Message(
      role: Role.assistant,
      content: [
        const ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'ls'}),
        const ToolResultBlock(
            toolUseId: 'c1', content: 'permission denied', isError: true),
      ],
    );
    final rows = view.render(message, width: 80);
    expect(rows[0].runs.first.text, '⏺ bash');
    expect(rows[0].runs.first.code, Theme.defaults().chat.red);
  });

  test('a chip without a result is still running (dim)', () {
    final message = Message(
      role: Role.assistant,
      content: [
        const ToolUseBlock(id: 'c1', name: 'glob', input: {'p': '*.dart'}),
      ],
    );
    final rows = view.render(message, width: 80);
    expect(rows[0].runs.first.code, Theme.defaults().chat.dim);
    expect(rows, hasLength(1)); // no ↳ row without output
  });

  test('user text renders bold, reasoning dim', () {
    final message = Message(
      role: Role.user,
      reasoning: [const ReasoningBlock('muttering')],
      content: [const TextBlock('fix the bug')],
    );
    final rows = view.render(message, width: 80);
    expect(rows[0].runs.single.text, '· muttering');
    expect(rows[0].runs.single.code, Theme.defaults().chat.dim);
    expect(rows[1].runs.single.text, 'fix the bug');
    expect(rows[1].runs.single.code, Theme.defaults().chat.userText);
  });

  test('prose wraps to the width budget', () {
    final message = Message(
      role: Role.assistant,
      content: [const TextBlock('one two three four five')],
    );
    final rows = view.render(message, width: 8);
    expect(rows.map((r) => r.runs.single.text), [
      'one two',
      'three',
      'four',
      'five',
    ]);
  });

  test('a call whose arguments did not parse shows the note, not args', () {
    final message = Message(
      role: Role.assistant,
      content: [
        const ToolUseBlock(
          id: 'c1',
          name: 'bash',
          input: {},
          argumentsParseError: "Unexpected character ''' at position 4",
        ),
      ],
    );
    final rows = view.render(message, width: 80);
    final line = rows.first.runs.map((r) => r.text).join();
    expect(line, contains('Unexpected character'));
    expect(line, isNot(contains('{}'))); // no JSON of the empty args
  });

  test('a result with no matching call in this message is skipped', () {
    final message = Message(
      role: Role.user,
      content: [
        const ToolResultBlock(toolUseId: 'ghost', content: 'boo'),
      ],
    );
    expect(view.render(message, width: 80), isEmpty);
  });
}
