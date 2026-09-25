import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina/tui/index_status_renderer.dart';

/// Pure-data renderer: formats an [IndexProgress] into the strip line,
/// e.g. `indexing / · 12/54`.
void main() {
  const renderer = IndexingStatusRenderer();
  const context = RenderContext(width: 80, theme: Theme.defaults());

  String text(IndexProgress value) => renderer
      .render(value, context)
      .expand((l) => l.runs)
      .map((r) => r.text)
      .join();

  test('renders the spinner frame plus done/total counts', () {
    expect(text(const IndexProgress(done: 12, total: 54)), contains('12/54'));
    expect(
      text(const IndexProgress(done: 12, total: 54)),
      matches(RegExp(r'^indexing [|/\\-] · 12/54$')),
    );
  });

  test('before the total is announced it spins without counts', () {
    expect(text(const IndexProgress(done: 0, total: 0)), 'indexing |');
  });

  test('the line is animated so the spinner advances', () {
    final line = renderer
        .render(const IndexProgress(done: 1, total: 9), context)
        .single;
    expect(line.animated, isTrue);
  });

  test('the label run is dim and the counts are unstyled', () {
    final runs = renderer
        .render(const IndexProgress(done: 1, total: 9), context)
        .expand((l) => l.runs)
        .toList();
    expect(runs.first.text, startsWith('indexing '));
    expect(runs.first.code, Theme.defaults().chat.dim);
    expect(runs.last.text, ' · 1/9');
    expect(runs.last.code, isNull);
  });
}
