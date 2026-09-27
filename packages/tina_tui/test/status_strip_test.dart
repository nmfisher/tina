import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_tui/tina_tui.dart';

/// Headless: rows at a couple of widths. The painter (`Screen.setStatusLines`)
/// owns where the strip sits; this is only the arrangement.
RenderLine line(String text, {StatusAlign? align}) =>
    RenderLine(runs: [RenderRun(text, null)], align: align);

int widthOf(List<RenderLine> rows) => rows.fold<int>(
      0,
      (w, r) => w + r.runs.fold<int>(0, (w, run) => w + visibleWidth(run.text)),
    );

void main() {
  test('mode label and plugin lines join at a wide width', () {
    final rows = statusStripRows(
      const StatusStripState(
        modeLabel: 'mode: ask',
        lines: [RenderLine(runs: [RenderRun('Σ 1,234', '2')])],
      ),
      80,
    );
    expect(rows, hasLength(2));
    expect(rows[0].runs.single.text, 'mode: ask');
    expect(rows[0].runs.single.code, '2'); // dim, like the app's strip
    expect(rows[1].runs.single.text, 'Σ 1,234');
    expect(widthOf(rows), lessThanOrEqualTo(80));
  });

  test('a right-aligned line anchors right and is dropped last', () {
    final rows = statusStripRows(
      StatusStripState(
        modeLabel: 'mode: ask',
        lines: [
          line('Σ 1,234', align: StatusAlign.right),
          line('index: ok'),
        ],
      ),
      40,
    );
    expect(rows.last.runs.single.text, 'Σ 1,234');
    expect(rows.first.runs.single.text, 'mode: ask');
    expect(rows[1].runs.single.text, 'index: ok');
  });

  test('under width pressure left lines drop from the end', () {
    final wide = statusStripRows(
      StatusStripState(
        modeLabel: 'mode: ask',
        lines: [line('index: ok'), line('spawned: 2')],
      ),
      80,
    );
    expect(wide.map((r) => r.runs.single.text).toList(),
        ['mode: ask', 'index: ok', 'spawned: 2']);

    final narrow = statusStripRows(
      StatusStripState(
        modeLabel: 'mode: ask',
        lines: [line('index: ok'), line('spawned: 2')],
      ),
      25,
    );
    expect(narrow.map((r) => r.runs.single.text).toList(),
        ['mode: ask', 'index: ok']);
  });

  test('the mode label survives; a huge right group clips, not crashes', () {
    final rows = statusStripRows(
      StatusStripState(
        modeLabel: 'mode: ask',
        lines: [line('r' * 100, align: StatusAlign.right)],
      ),
      20,
    );
    expect(rows.map((r) => r.runs.single.text), ['r' * 100]);
    // Width 0/1 edge: nothing sensible to paint.
    expect(statusStripRows(const StatusStripState(modeLabel: 'm'), 0), isEmpty);
  });

  test('an empty state renders no rows', () {
    expect(statusStripRows(const StatusStripState(), 80), isEmpty);
  });
}
