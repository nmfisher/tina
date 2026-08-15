import 'package:tina_console/tina_console.dart';
import 'package:tina/chat_agent_sink.dart';
import 'package:tina/tui/run_panel_content.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// Pins [RunPanelContent]'s transcript presentation: the wrapped
/// [ScrollingTextRegion] renders the run's streamed text (agent text +
/// notices, exactly as [ChatAgentSink] writes them), the bottom row carries
/// the dim "input disabled" label, and fit/attach/detach paint without
/// crashing — including a degenerate 1-row interior.
void main() {
  late FakeStdio io;
  late Screen screen;

  setUp(() {
    io = FakeStdio()..columns = 120;
    final layout =
        ScreenLayout.fromSize(120, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
  });

  /// A content over a fresh detached region, like the coordinator builds
  /// (region born at the info rect, detached until relayContent fits it).
  RunPanelContent content() {
    final chat = ScrollingTextRegion(screen, bounds: screen.layout.info)
      ..detach();
    return RunPanelContent(screen: screen, chat: chat);
  }

  test('the transcript renders streamed text above the disabled-input label',
      () {
    final c = content();
    // Stream like a node agent would: a progress notice + streamed prose.
    final sink = ChatAgentSink(c.chat, Spinner(enabled: false));
    sink.notice('▶ intake');
    sink.text('working on it');
    sink.newline();
    c.fit(const Rect(row: 3, col: 78, width: 40, height: 12),
        reserveInputRow: false);
    c.attach();

    final out = io.written.toString();
    expect(out, contains('▶ intake'));
    expect(out, contains('working on it'));
    // The bottom row carries the read-only notice (input is disabled); in a
    // 40-col panel the label is clipped, so assert on its head.
    expect(out, contains('s stop · x close'));
  });

  test('fit/attach/detach paint without crashing', () {
    final c = content();
    c.fit(const Rect(row: 3, col: 78, width: 40, height: 18),
        reserveInputRow: false);
    c.attach();
    c.detach();
    c.fit(const Rect(row: 3, col: 78, width: 38, height: 16),
        reserveInputRow: false);
    c.attach();
    c.detach();
  });

  test('a degenerate 1-row interior still paints the label', () {
    final c = content();
    c.fit(const Rect(row: 3, col: 78, width: 40, height: 1),
        reserveInputRow: false);
    c.attach();
    expect(io.written.toString(), contains('s stop · x close'));
  });
}
