import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina/tui/token_status_renderer.dart';

/// Pure-data renderer: no streams, no scopes — only formats a
/// [TokenUsageSummary] into strip lines.
void main() {
  const renderer = TokenUsageRenderer();
  const context = RenderContext(width: 80, theme: Theme.defaults());

  String text(TokenUsageSummary value) => renderer
      .render(value, context)
      .expand((l) => l.runs)
      .map((r) => r.text)
      .join();

  test('renders the bare measured total when unbounded', () {
    expect(
      text(
        const TokenUsageSummary(
          totalTokens: 12345,
          estimatedTokens: 0,
          seededTokens: 0,
          cap: null,
          tripped: false,
          rpm: 0,
        ),
      ),
      'Σ 12,345',
    );
  });

  test('renders the cap share and colors it dim below 75%', () {
    final value = const TokenUsageSummary(
      totalTokens: 12345,
      estimatedTokens: 0,
      seededTokens: 0,
      cap: 30000,
      tripped: false,
      rpm: 0,
    );
    expect(text(value), 'Σ 12,345 / 30,000 · 41%');
    final runs = renderer.render(value, context).expand((l) => l.runs);
    final capRun = runs.last;
    expect(capRun.text, contains('/ 30,000'));
    expect(capRun.code, Theme.defaults().chat.dim);
  });

  test('yellows the cap share from 75% and reds it from 90%', () {
    TokenUsageSummary at(int total) => TokenUsageSummary(
      totalTokens: total,
      estimatedTokens: 0,
      seededTokens: 0,
      cap: 1000,
      tripped: false,
      rpm: 0,
    );
    final theme = Theme.defaults().chat;
    expect(
      renderer.render(at(700), context).expand((l) => l.runs).last.code,
      theme.dim,
    );
    expect(
      renderer.render(at(760), context).expand((l) => l.runs).last.code,
      theme.yellow,
    );
    expect(
      renderer.render(at(920), context).expand((l) => l.runs).last.code,
      theme.red,
    );
  });

  test('estimated failed-attempt spend is shown distinctly', () {
    expect(
      text(
        const TokenUsageSummary(
          totalTokens: 12345,
          estimatedTokens: 2100,
          seededTokens: 0,
          cap: null,
          tripped: false,
          rpm: 0,
        ),
      ),
      'Σ 12,345 +~2,100 est',
    );
  });

  test('the trip latch replaces everything with a red TRIPPED line', () {
    final lines = renderer.render(
      const TokenUsageSummary(
        totalTokens: 40000,
        estimatedTokens: 0,
        seededTokens: 0,
        cap: 30000,
        tripped: true,
        rpm: 0,
      ),
      context,
    );
    expect(lines, hasLength(1));
    expect(lines.first.runs.single.text, 'SPEND LIMIT TRIPPED');
    expect(lines.first.runs.single.code, Theme.defaults().chat.red);
  });

  test('every line requests the right-aligned slot on the strip', () {
    final lines = renderer.render(
      const TokenUsageSummary(
        totalTokens: 1,
        estimatedTokens: 0,
        seededTokens: 0,
        cap: null,
        tripped: false,
        rpm: 0,
      ),
      context,
    );
    expect(lines.first.align, StatusAlign.right);
  });
}
