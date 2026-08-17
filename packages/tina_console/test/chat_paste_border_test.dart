import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// tin-q4vz: after a large pasted message (many wrapped lines, forcing the
/// chat region to scroll repeatedly), some interior rows render with a space
/// where the panel's left border `│` belongs — and when the text contains
/// wide chars, the first row of a wrapped line can also drop a glyph
/// (`long-token:` rendered as ` long-toke :`). These tests reproduce the
/// corpus shape at the VirtualTerminal level: write a multi-section body
/// into a framed chat region and assert the border column survives every
/// content row.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;

  setUp(() {
    io = FakeStdio()..columns = 100;
    final layout =
        ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  (PanelFrame, ChatRegionPanelContent, ScrollingTextRegion) _panelWithChat(
      Rect rect) {
    final chat = ScrollingTextRegion(screen, bounds: screen.layout.info)
      ..detach();
    final content = ChatRegionPanelContent(chat);
    final frame = PanelFrame(screen: screen, label: 'm', conversationId: 'c1')
      ..setReservesInput(true);
    frame.setOuter(rect);
    content.fit(frame.interior, reserveInputRow: frame.reservesInput);
    if (content.isDetached) content.attach();
    return (frame, content, chat);
  }

  // The seed corpus shape, scaled to the small panel: sections of five lines
  // whose fourth line wraps (a >width token), pushing the region through
  // many scrolls.
  //
  // The wide line is sized for the defect: 56 CJK chars + the emoji clusters
  // are ~49 more CODE UNITS than the plain prefix, so the old one-column-
  // per-unit budget could hold a model row inside the region while a real
  // terminal lays the same glyphs out ~2x wider — the overflow that ran past
  // the panel edge and autowrapped over the border (tin-q4vz).
  String body({bool wide = false, int sections = 12}) => List.generate(
        sections,
        (i) => [
          '-- section $i --',
          'the quick brown fox jumps over the lazy dog 0123456789',
          if (wide) 'CJK: ${'漢字テスト混合' * 8} $i · emoji: 🏳️‍🌈 👨‍👩‍👧‍👦 ✓',
          'long-token: ${'x' * 80}$i',
          'plain indented line ends',
        ].join('\n'),
      ).join('\n');

  void drain() {
    vt.feed(io.written.toString());
    io.written.clear();
  }

  test('every interior row keeps its left border after a scrolling paste',
      () {
    final rect = const Rect(row: 2, col: 4, width: 60, height: 18);
    final (frame, _, chat) = _panelWithChat(rect);
    drain(); // border draw

    chat.write(body());
    drain();

    final interior = frame.interior;
    final missing = <int>[];
    for (var r = 0; r < interior.height; r++) {
      final cell = vt.charAt(interior.row + r, interior.col - 1);
      if (cell != '│') missing.add(interior.row + r);
    }
    expect(missing, isEmpty,
        reason:
            'rows lost the left border (tin-q4vz): got ${missing.take(8).toList()}');
  });

  test('a wide-char body keeps both border and glyphs on wrapped rows', () {
    final rect = const Rect(row: 2, col: 4, width: 60, height: 18);
    final (_, _, chat) = _panelWithChat(rect);
    drain();

    final text = body(wide: true);
    chat.write(text);
    drain();

    // Both border columns — the left one via the terminal's autowrap, the
    // right one via content that simply paints past the region edge.
    final interior = const Rect(row: 3, col: 5, width: 58, height: 16);
    final missing = <int>[];
    for (var r = 0; r < interior.height; r++) {
      if (vt.charAt(interior.row + r, interior.col - 1) != '│') {
        missing.add(interior.row + r);
      }
      if (vt.charAt(interior.row + r, interior.col + interior.width) != '│') {
        missing.add(interior.row + r);
      }
    }
    expect(missing, isEmpty, reason: 'border loss (tin-q4vz)');

    // …and the exact text: every non-wrapped line must appear intact in the
    // region (the dropped-glyph symptom showed `long-toke :` for
    // `long-token:`).
    final screenText = List.generate(
      24,
      (r) => List.generate(100, (c) => vt.charAt(r, c)).join(),
    ).join('\n');
    for (final line in [
      '-- section 11 --',
      'the quick brown fox jumps over the lazy dog 0123456789',
      'plain indented line ends',
    ]) {
      expect(screenText, contains(line),
          reason: 'line corrupted on screen: $line');
    }
  });

  test('a full-width panel survives wide rows reaching the terminal edge',
      () {
    // The live-app geometry: the chat interior extends to the terminal's
    // right edge, so an over-budget wide row doesn't just paint past the
    // panel — the TERMINAL autowraps it onto the next screen row, eating
    // the left border and the first glyphs of the row below.
    final rect = const Rect(row: 2, col: 4, width: 96, height: 18);
    final (frame, _, chat) = _panelWithChat(rect);
    drain();

    chat.write(body(wide: true));
    drain();

    final interior = frame.interior;
    expect(interior.col + interior.width, 99,
        reason: 'fixture premise: interior must reach the terminal edge');

    final missing = <int>[];
    for (var r = 0; r < interior.height; r++) {
      if (vt.charAt(interior.row + r, interior.col - 1) != '│') {
        missing.add(interior.row + r);
      }
      if (vt.charAt(interior.row + r, interior.col + interior.width) != '│') {
        missing.add(interior.row + r);
      }
    }
    expect(missing, isEmpty,
        reason:
            'rows lost a border to autowrap (tin-q4vz): got ${missing.take(8).toList()}');

    // The row following a wide row must render its text exactly — the
    // dropped-glyph symptom (`long-token:` → ` long-toke :`).
    final screenText = List.generate(
      24,
      (r) => List.generate(100, (c) => vt.charAt(r, c)).join(),
    ).join('\n');
    expect(screenText, contains('long-token:'),
        reason: 'long-token row corrupted by the wide row above it');
    expect(screenText, contains('-- section 11 --'),
        reason: 'section header corrupted');
  });
}
