import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';

import 'console_test.dart' show Io;
import 'image_test.dart' show Images, image;

/// A synthetic long session: 125 turns, ~500 transcript blocks, images in
/// turns 24/49/74/99/124 — the last one lands in the resumed viewport.
List<SessionEntry> longSession() {
  final entries = <SessionEntry>[];
  for (var t = 0; t < 125; t++) {
    final id = 't$t';
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000 + t * 1000)
        .toUtc()
        .toIso8601String();
    entries.add(TurnStartedEntry(turnId: id, at: at));
    entries.add(InputRecordedEntry(
        turnId: id, text: 'Question $t: analyze sector ${t % 9}.', at: at));
    entries.add(MessageAppendedEntry(
        turnId: id,
        at: at,
        message: Message(role: Role.user, content: [
          TextBlock('Question $t: analyze the flux readings for sector '
              '${t % 9} and summarize the anomaly.'),
        ])));
    entries.add(MessageAppendedEntry(
        turnId: id,
        at: at,
        message: Message(role: Role.assistant, content: [
          TextBlock('Reading ${t % 9}: the flux readings show a steady drift '
              'in sector ${t % 7} that started after the last calibration '
              'pass.\n\nTwo things stand out. First, the anomaly is periodic '
              'with the sampling window, which usually points at the probe '
              'rather than the medium. Second, the magnitude grows with '
              'temperature, not with load.'),
        ])));
    entries.add(MessageAppendedEntry(
        turnId: id,
        at: at,
        message: Message(role: Role.assistant, content: [
          ToolUseBlock(
              id: 'c$t',
              name: 'bash',
              input: {'command': 'grep -rn anomaly sector-${t % 9}/logs'})
        ])));
    entries.add(MessageAppendedEntry(
        turnId: id,
        at: at,
        message: Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 'c$t', content: 'sector-${t % 9}: ok')
        ])));
    if (t % 25 == 24) {
      entries.add(MessageAppendedEntry(
          turnId: id,
          at: at,
          message: Message(role: Role.assistant, content: [image])));
    }
    entries.add(TurnEndedEntry(
        turnId: id,
        reason: TurnStopReason.complete,
        usage: const EntryUsage(),
        at: at));
  }
  return entries;
}

void main() {
  late Io io;
  late Images backend;
  late Screen screen;
  late LineEditor editor;
  late ChatPlugin plugin;
  late AgentLoop loop;
  late ChatView chat;

  setUp(() {
    io = Io();
    backend = Images(io);
    screen = Screen.withBackend(
        io: io,
        backend: backend,
        layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    plugin = ChatPlugin(model: 'test');
    loop = AgentLoop(
        provider: ScriptedProvider(const []),
        plugins: [],
        seedLog: longSession());
    plugin.mountOn(loop);
    chat =
        ChatView(plugin.observation, now: () => DateTime(2026, 9, 28, 3, 4, 5));
  });
  tearDown(() {
    chat.detachConsole();
    plugin.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  String written() => screen.chat.snapshotLines().join('\n');

  test('resume writes only the tail window, not the whole history', () {
    chat.attachConsole(ConsoleContext(screen: screen, editor: editor));
    // The whole block list is in memory…
    expect(chat.blocks.length, greaterThan(300));
    // …but only a viewport plus margin of rows was built.
    expect(screen.chat.contentRows,
        lessThanOrEqualTo(screen.chat.usableHeight + 160 + 8));
    expect(written(), contains('Question 124')); // the tail is shown…
    expect(written(), isNot(contains('Question 100'))); // …the head was not
  });

  test('scrolling up builds only the rows it needs, without gaps', () async {
    chat.attachConsole(ConsoleContext(screen: screen, editor: editor));
    final firstRows = screen.chat.contentRows;
    var previous = firstRows;
    for (var page = 0; page < 6; page++) {
      screen.chat.scrollBy(-screen.chat.usableHeight);
      await Future<void>.delayed(Duration.zero);
      final rows = screen.chat.contentRows;
      // Each page extends the window by at most one margin refill.
      expect(rows - previous, lessThanOrEqualTo(160 + 8));
      // No blank gap: the rows above the viewport are real content.
      expect(screen.chat.snapshotLines(), isNotEmpty);
      previous = rows;
    }
    expect(previous, greaterThan(firstRows));
    expect(written(), contains('Question 11')); // paged into older history
  });

  test('resumed history images decode only when scrolled toward', () async {
    chat.attachConsole(ConsoleContext(screen: screen, editor: editor));
    // The tail image (turn 124) is in the resumed viewport: decoded now.
    final tailPlaced = backend.visible[screen.chat]!;
    expect(tailPlaced, isNotEmpty);
    // The older images are cold — not written, not decoded, not placed.
    expect(written(), isNot(contains('Question 99')));
    // Page up until a history image's reserved rows enter the viewport:
    // it must decode and place in place, with the view still scrolled up.
    for (var page = 0; page < 16; page++) {
      if ((backend.visible[screen.chat]?.length ?? 0) > 0 &&
          screen.chat.debugScrollOffset > 0) {
        break;
      }
      screen.chat.scrollBy(-screen.chat.usableHeight);
      await Future<void>.delayed(Duration.zero);
    }
    expect(screen.chat.debugScrollOffset, greaterThan(0));
    final placed = backend.visible[screen.chat];
    expect(placed, isNotNull);
    expect(placed!, isNotEmpty);
  });

  test('fold navigation and selection work inside the resumed window',
      () async {
    final line = editor.readLine('unused');
    chat.attachConsole(ConsoleContext(screen: screen, editor: editor));
    await Future<void>.delayed(Duration.zero);
    io.feed('draft\x02'); // enter transcript selection on the last foldable
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(screen.chat.debugScrollOffset, 0);
    io.feed('\r'); // expand the folded tool call under the cursor
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(written(), contains('sector-7: ok')); // 124 % 9 == 7
    io.feed('\r'); // fold it back
    await Future<void>.delayed(const Duration(milliseconds: 40));
    io.feed('\x1b'); // leave selection
    await Future<void>.delayed(const Duration(milliseconds: 40));
    io.feed(' intact\r');
    expect(await line, 'draft intact');
  });
}
