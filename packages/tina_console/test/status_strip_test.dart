import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Permission mode and plugin status share the strip beneath the input row.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;
  late ScreenLayout layout;

  setUp(() {
    io = FakeStdio();
    layout = ScreenLayout.fromSize(100, 24);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  test('plugin status survives redraw and clearing preserves the mode', () {
    screen.setModeLabel('mode: auto');
    screen.setStatusLines(const [
      RenderLine(runs: [RenderRun('Last input: git push', null)])
    ]);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('mode: auto'));
    expect(row, contains('Last input: git push'));
    screen.setStatusLines(const []);
    vt.feed(io.written.toString());
    expect(vt.rowText(layout.stripRow), isNot(contains('git push')));
    expect(vt.rowText(layout.stripRow), contains('mode: auto'));
  });

  test('plugin status is clipped and cannot inject terminal controls', () {
    screen.setStatusLines([
      RenderLine(runs: [RenderRun('status\n\x1b[2J${'x' * 200}', null)])
    ]);
    vt.feed(io.written.toString());
    expect(vt.rowText(layout.stripRow), contains('status'));
    expect(vt.charAt(layout.stripRow, 99), ' ');
    expect(vt.rowText(layout.bottomBorderRow), contains('└'));
  });

  test('a mode-label update repaints the strip in place', () {
    screen.setModeLabel('mode: ask');
    screen.setModeLabel('mode: auto');
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('mode: auto'));
    expect(row, isNot(contains('mode: ask')));
  });

  RenderLine _line(String text, {StatusAlign? align}) =>
      RenderLine(align: align, runs: [RenderRun(text, null)]);

  test('right-aligned lines anchor to the strip right edge', () {
    screen.setStatusLines([
      _line('Σ 12,345 / 30,000 · 41%', align: StatusAlign.right),
    ]);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('Σ 12,345 / 30,000 · 41%'));
    // Flush right inside the strip (inner cols 1..98 of a 100-wide row): the
    // text ends at the last inner column, index 98.
    expect(row.trimRight().length, 99);
    expect(vt.charAt(layout.stripRow, 98), '%'); // last char of '41%'
    expect(vt.charAt(layout.stripRow, 99), ' '); // border column untouched
  });

  test('left lines are clipped before the right-anchored text', () {
    screen.setModeLabel('mode: auto');
    screen.setStatusLines([
      _line('left ' * 40), // 200 chars — far wider than the budget
      _line('RIGHT', align: StatusAlign.right),
    ]);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row.trimRight().length, 99);
    expect(row, contains('mode: auto'));
    expect(row.trimRight().endsWith('RIGHT'), isTrue);
    // The left group was clipped into the gap left of the right anchor: the
    // repeated filler stops well before the anchored text.
    final leftEnd = row.indexOf('  ') + 2; // end of the clipped filler run
    expect(leftEnd < 90, isTrue, reason: 'filler must not run under RIGHT');
  });

  test('a layout plugin rearranges the strip; null restores the default', () {
    screen.setStatusLines([_line('Last input: git push')]);
    screen.setStatusLayout(_RightOf('WRAPPED BY PLUGIN'));
    vt.feed(io.written.toString());
    var row = vt.rowText(layout.stripRow);
    expect(row, contains('Last input: git push'));
    expect(row.trimRight().endsWith('WRAPPED BY PLUGIN'), isTrue);

    screen.setStatusLayout(null);
    vt.feed(io.written.toString());
    row = vt.rowText(layout.stripRow);
    expect(row, contains('Last input: git push'));
    expect(row, isNot(contains('WRAPPED BY PLUGIN')));
  });

  test('a throwing layout falls back to the default arrangement', () {
    screen.setModeLabel('mode: auto');
    screen.setStatusLines([_line('Last input: git push')]);
    screen.setStatusLayout(_ThrowingLayout());
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('mode: auto'));
    expect(row, contains('Last input: git push'));
  });
}

/// Wraps [text] around the plugin lines, right-aligned.
class _RightOf implements StatusLayout {
  final String text;
  const _RightOf(this.text);

  @override
  List<RenderLine> arrange(StatusContent content, int width) => [
        ...content.lines,
        RenderLine(align: StatusAlign.right, runs: [RenderRun(text, null)]),
      ];
}

class _ThrowingLayout implements StatusLayout {
  @override
  List<RenderLine> arrange(StatusContent content, int width) =>
      throw StateError('plugin layout blew up');
}
