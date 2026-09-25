import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina/tui/status_layout_plugin.dart';

RenderLine _line(String text, {StatusAlign? align}) =>
    RenderLine(align: align, runs: [RenderRun(text, null)]);

List<String> _texts(List<RenderLine> lines) =>
    lines.map((l) => l.runs.map((r) => r.text).join()).toList();

/// The strip's layout policy: the right group (the token counter's slot) never
/// shrinks under width pressure; left lines die from the end backward.
void main() {
  const layout = PriorityStatusLayout();

  test('passes content through unchanged when everything fits', () {
    final arranged = layout.arrange(
      StatusContent(
        modeLabel: 'mode: auto',
        lines: [
          _line('Last input: git push'),
          _line('Σ 12,345 / 30,000 · 41%', align: StatusAlign.right),
        ],
      ),
      98,
    );
    expect(_texts(arranged), [
      'mode: auto',
      'Last input: git push',
      'Σ 12,345 / 30,000 · 41%',
    ]);
    expect(arranged[2].align, StatusAlign.right);
  });

  test('keeps the right group and drops left lines end-backward', () {
    final arranged = layout.arrange(
      StatusContent(
        modeLabel: 'mode: auto',
        lines: [
          _line('checking intent'),
          _line('Last input: git push'),
          _line('Σ 12,345', align: StatusAlign.right),
        ],
      ),
      30, // 'mode: auto' + gap + 'Σ 12,345' = 21; no room for line 2.
    );
    expect(_texts(arranged), ['mode: auto', 'Σ 12,345']);
  });

  test('an empty left group leaves the right line alone', () {
    final arranged = layout.arrange(
      StatusContent(lines: [_line('Σ 12,345', align: StatusAlign.right)]),
      98,
    );
    expect(_texts(arranged), ['Σ 12,345']);
  });

  test('the mode label survives until it alone cannot fit', () {
    final arranged = layout.arrange(
      StatusContent(
        modeLabel: 'mode: auto',
        lines: [
          _line('Last input: git push'),
          _line('Σ 12,345', align: StatusAlign.right),
        ],
      ),
      13, // right(8) + gap(2) + label(10) > 13 — label loses.
    );
    expect(_texts(arranged), ['Σ 12,345']);
  });

  test(
    'a right group wider than the strip still comes back (painter clips)',
    () {
      final arranged = layout.arrange(
        StatusContent(
          modeLabel: 'mode: auto',
          lines: [
            _line('Last input: git push'),
            _line('Σ 12,345 / 300,000 · 4%', align: StatusAlign.right),
          ],
        ),
        10,
      );
      expect(_texts(arranged), ['Σ 12,345 / 300,000 · 4%']);
    },
  );

  test('zero width arranges nothing', () {
    expect(
      layout.arrange(
        StatusContent(modeLabel: 'mode: auto', lines: [_line('x')]),
        0,
      ),
      isEmpty,
    );
  });
}
