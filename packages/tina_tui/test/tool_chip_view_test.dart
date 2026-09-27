import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_tui/tina_tui.dart';

/// Headless: chip state transitions and their rows.
void main() {
  final call = const ToolUse(id: 'c1', name: 'edit', input: {
    'path': 'lib/main.dart',
    'oldString': 'foo',
    'newString': 'bar',
  });

  test('a chip line for a tool use and result', () {
    // Running: dim marker, no output row.
    final running = toolChipRows(call, null, width: 80);
    expect(running, hasLength(1));
    expect(running[0].runs.first.text, '⏺ edit');
    expect(running[0].runs.first.code, Theme.defaults().chat.dim);
    expect(running[0].runs.last.text, contains('path: "lib/main.dart"'));

    // Success: green marker plus a dim ↳ row from the output.
    final done = toolChipRows(
      call,
      const ToolResult('ok\nsecond line'),
      width: 80,
    );
    expect(done[0].runs.first.code, Theme.defaults().chat.green);
    expect(done[1].runs.single.text, '  ↳ ok');

    // Error: red marker.
    final failed = toolChipRows(
      call,
      const ToolResult('nope', isError: true),
      width: 80,
    );
    expect(failed[0].runs.first.code, Theme.defaults().chat.red);
  });

  test('the chip state transitions run → success/error on the shared chip',
      () {
    final chip = ToolChipView.chip(call);
    expect(chip.state, ToolChipState.running);
    expect(chip.toolName, 'edit');
    expect(chip.toolId, 'c1');

    ToolChipView.complete(chip, const ToolResult('done'));
    expect(chip.state, ToolChipState.success);
    expect(chip.outputBuffer.toString(), 'done');

    ToolChipView.complete(chip, const ToolResult('bad', isError: true));
    expect(chip.state, ToolChipState.error);
    expect(chip.outputBuffer.toString(), 'done\nbad');
  });

  test('the summary is name plus compact args; parse error replaces them',
      () {
    expect(ToolChipView.summary(call),
        'edit path: "lib/main.dart", oldString: "foo", newString: "bar"');
    expect(
      ToolChipView.summary(const ToolUse(
        id: 'c2',
        name: 'bash',
        input: {},
        argumentsParseError: 'bad JSON',
      )),
      'bash bad JSON',
    );
    expect(
      ToolChipView.summary(const ToolUse(id: 'c3', name: 'stat', input: {})),
      'stat',
    );
  });

  test('long arguments are truncated with an ellipsis, never wrapped', () {
    final rows = toolChipRows(
      ToolUse(
        id: 'c1',
        name: 'bash',
        input: {'command': 'x' * 200},
      ),
      null,
      width: 40,
    );
    expect(rows, hasLength(1));
    final text = rows[0].runs.last.text;
    expect(text.endsWith('…'), isTrue);
    final lineWidth = rows[0].runs.fold<int>(
      0,
      (w, r) => w + visibleWidth(r.text),
    );
    expect(lineWidth, lessThanOrEqualTo(40));
  });
}
