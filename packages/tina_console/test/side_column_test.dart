import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

/// The side column: classifier, plans, channel in a fixed strip right
/// of the conversation. These tests pin the geometry math — width
/// partitioning, fixed order regardless of open order, vertical
/// distribution and collapse, and the narrow-terminal fallback to the
/// stacked sidebar geometry. The channel pane's render at column width
/// is covered by the tina_channel_tui suite.
void main() {
  SideColumnLayout columnFor(
      ScreenLayout current, void Function(ScreenLayout) replace) {
    var layout = current;
    return SideColumnLayout(
        layout: () => layout,
        setReservation: (width) {
          replace(layout = ScreenLayout.fromSize(layout.width, layout.height,
              split: layout.isSplit,
              hasMenuBar: layout.hasMenuBar,
              rightColumnWidth: width));
        });
  }

  test('width constants: a third of the screen, clamped, with a floor', () {
    expect(SideColumnLayout.panelWidthFor(96), 40);
    expect(SideColumnLayout.panelWidthFor(108), 40);
    expect(SideColumnLayout.panelWidthFor(120), 40);
    expect(SideColumnLayout.panelWidthFor(156), 52);
    expect(SideColumnLayout.panelWidthFor(200), 52);
    // The threshold: below 100 the column is not applied at all (96-99
    // would leave the conversation under its 60-column floor; 95 and
    // down fail the minimum width outright).
    expect(SideColumnLayout.fits(95), isFalse);
    expect(SideColumnLayout.fits(96), isFalse);
    expect(SideColumnLayout.fits(99), isFalse);
    expect(SideColumnLayout.fits(100), isTrue);
    // At the threshold the conversation keeps its minimum.
    expect(100 - SideColumnLayout.panelWidthFor(100),
        greaterThanOrEqualTo(SideColumnLayout.minConversationWidth));
  });

  test('an open panel reserves the column; closing releases it', () async {
    var layout = ScreenLayout.fromSize(120, 30, split: false);
    final column = columnFor(
        layout, (next) => layout = next);
    final classifier =
        column.register(() {}, rank: SideColumnRank.classifier);
    expect(layout.rightColumn, isEmpty);
    classifier.requestSize(height: 8);
    await pumpEventQueue();
    expect(layout.rightColumn.width, SideColumnLayout.panelWidthFor(120));
    expect(layout.chat.width, 120 - SideColumnLayout.panelWidthFor(120) - 2);
    classifier.requestSize(height: 0);
    await pumpEventQueue();
    expect(layout.rightColumn, isEmpty);
    expect(layout.chat.width, 118);
  });

  test('fixed order top to bottom regardless of registration order',
      () async {
    // Tall enough that the channel's remainder is a real majority
    // (on a 30-row terminal the column is 26 rows: 8+6 requests leave
    // the channel only 12, and the majority claim is untestable).
    var layout = ScreenLayout.fromSize(120, 40, split: false);
    final column = columnFor(layout, (next) => layout = next);
    // Registered channel, classifier, plans — opened plans, channel,
    // classifier. Order stays classifier, plans, channel.
    final channel = column.register(() {}, rank: SideColumnRank.channel);
    final classifier =
        column.register(() {}, rank: SideColumnRank.classifier);
    final plans = column.register(() {}, rank: SideColumnRank.plans);
    plans.requestSize(height: 6);
    channel.requestSize(height: 10000);
    classifier.requestSize(height: 8);
    await pumpEventQueue();

    final area = layout.rightColumn;
    expect(classifier.bounds.row, area.row);
    expect(classifier.bounds.col, area.col);
    expect(classifier.bounds.width, area.width);
    expect(classifier.bounds.height, 8);
    expect(plans.bounds.row, area.row + 8);
    expect(plans.bounds.col, area.col);
    expect(plans.bounds.width, area.width);
    expect(plans.bounds.height, 6);
    // Channel takes the remainder — the majority of the column.
    expect(channel.bounds.col, area.col);
    expect(channel.bounds.width, area.width);
    expect(channel.bounds.row, area.row + 14);
    expect(channel.bounds.height, area.height - 14);
    expect(
        channel.bounds.height,
        greaterThan(
            classifier.bounds.height + plans.bounds.height));
    expect(channel.bounds.bottom, area.bottom);
  });

  test('one panel: the channel pane owns the whole column', () async {
    var layout = ScreenLayout.fromSize(120, 30, split: false);
    final column = columnFor(layout, (next) => layout = next);
    final channel = column.register(() {}, rank: SideColumnRank.channel)
      ..requestSize(height: 10000);
    await pumpEventQueue();
    final area = layout.rightColumn;
    expect(channel.bounds.row, area.row);
    expect(channel.bounds.col, area.col);
    expect(channel.bounds.width, area.width);
    expect(channel.bounds.height, area.height);
  });

  test('a focused inspector takes the column; later panels keep minimums',
      () async {
    var layout = ScreenLayout.fromSize(120, 30, split: false);
    final column = columnFor(layout, (next) => layout = next);
    final classifier =
        column.register(() {}, rank: SideColumnRank.classifier);
    final plans = column.register(() {}, rank: SideColumnRank.plans);
    final channel = column.register(() {}, rank: SideColumnRank.channel);
    classifier.requestSize(height: 8);
    plans.requestSize(height: 6);
    channel.requestSize(height: 10000);
    await pumpEventQueue();

    // Focus maximizes the classifier within the column: everything
    // else drops to its minimum (plans 4, channel 8).
    classifier.requestSize(height: 10000, focused: true);
    await pumpEventQueue();
    final area = layout.rightColumn;
    expect(classifier.bounds.height, area.height - 4 - 8);
    expect(plans.bounds.height, SideColumnLayout.panelMinimumHeight);
    expect(channel.bounds.height, SideColumnLayout.channelMinimumHeight);
    // Restoring the compact request returns the normal stack.
    classifier.requestSize(height: 8, focused: false);
    await pumpEventQueue();
    expect(classifier.bounds.height, 8);
    expect(channel.bounds.bottom, area.bottom);
  });

  test('vertical overflow collapses the earlier ranks, channel keeps its minimum',
      () async {
    var layout =
        ScreenLayout.fromSize(120, 12, split: false); // short column
    final column = columnFor(layout, (next) => layout = next);
    final classifier =
        column.register(() {}, rank: SideColumnRank.classifier);
    final plans = column.register(() {}, rank: SideColumnRank.plans);
    final channel = column.register(() {}, rank: SideColumnRank.channel);
    classifier.requestSize(height: 8);
    plans.requestSize(height: 6);
    channel.requestSize(height: 10000);
    await pumpEventQueue();

    // The column is 8 rows tall; the three minimums (4+4+8) cannot
    // fit, so the earlier ranks collapse and the channel pane — the
    // one with the largest minimum — keeps a usable height.
    expect(classifier.bounds.width, 0);
    expect(classifier.bounds.height, 0);
    expect(plans.bounds.width, 0);
    expect(plans.bounds.height, 0);
    expect(channel.bounds.height,
        greaterThanOrEqualTo(SideColumnLayout.channelMinimumHeight));
    expect(channel.bounds.bottom, layout.rightColumn.bottom);

    // With room for exactly two minimums, plans keeps its minimum and
    // the channel keeps the rest (the classifier still yields).
    var taller = ScreenLayout.fromSize(120, 16, split: false);
    final column2 = columnFor(taller, (next) => taller = next);
    final classifier2 =
        column2.register(() {}, rank: SideColumnRank.classifier);
    final plans2 = column2.register(() {}, rank: SideColumnRank.plans);
    final channel2 = column2.register(() {}, rank: SideColumnRank.channel);
    classifier2.requestSize(height: 8);
    plans2.requestSize(height: 6);
    channel2.requestSize(height: 10000);
    await pumpEventQueue();
    // Column height 12: 4+4+8 = 16 > 12 → classifier collapses; plans
    // is capped at 4 (channel's minimum protected), channel keeps 8.
    expect(classifier2.bounds.height, 0);
    expect(plans2.bounds.height, SideColumnLayout.panelMinimumHeight);
    expect(channel2.bounds.height, SideColumnLayout.channelMinimumHeight);
  });

  test('narrow terminals fall back to the stacked sidebar geometry',
      () async {
    var layout = ScreenLayout.fromSize(80, 24, split: false);
    final column = columnFor(layout, (next) => layout = next);
    final classifier =
        column.register(() {}, rank: SideColumnRank.classifier);
    final plans = column.register(() {}, rank: SideColumnRank.plans);
    plans.requestSize(height: 6, width: 44);
    classifier.requestSize(height: 8, width: 44);
    await pumpEventQueue();

    // No reservation: the conversation keeps the full width, and the
    // panels stack as overlays over the chat's right edge (today's
    // layout), each with its own requested width.
    expect(layout.rightColumn, isEmpty);
    expect(layout.chat.width, 78);
    expect(column.active, isFalse);
    final chat = layout.chat;
    expect(classifier.bounds.col, chat.right - 44 + 1);
    expect(classifier.bounds.width, 44);
    expect(plans.bounds.bottom, lessThan(classifier.bounds.row));
    // Hiding releases the stacked space, as the sidebar always did.
    classifier.requestSize(height: 0);
    await pumpEventQueue();
    expect(plans.bounds.height, 6);
  });

  // A panel re-request after a threshold-crossing resize releases
  // the strip: the conversation is whole again.
  test('a resize across the threshold releases the column', () async {
    var layout = ScreenLayout.fromSize(100, 24, split: false);
    final column = SideColumnLayout(
        layout: () => layout,
        setReservation: (width) {
          layout = ScreenLayout.fromSize(layout.width, layout.height,
              split: layout.isSplit, rightColumnWidth: width);
        });
    final classifier =
        column.register(() {}, rank: SideColumnRank.classifier);
    classifier.requestSize(height: 8);
    await pumpEventQueue();
    expect(layout.rightColumn.width, 40);

    // The terminal shrinks below what the column needs. The same
    // panel request re-evaluates against the new width: no column,
    // no reservation, full-width conversation.
    layout = ScreenLayout.fromSize(40, 10, split: false);
    classifier.requestSize(height: 8); // unchanged request, new width
    await pumpEventQueue();
    expect(layout.rightColumn, isEmpty);
    expect(layout.chat.width, 38);
  });

  test('Screen.setRightColumn narrows the conversation and survives resizes',
      () {
    final io = _Io();
    final screen = Screen(
        io: io,
        ansi: AnsiCapable.yes,
        layout: ScreenLayout.fromSize(120, 30, split: false));
    expect(screen.layout.chat.width, 118);
    screen.setRightColumn(40);
    expect(screen.layout.chat.width, 78);
    expect(screen.layout.rightColumn.width, 40);
    expect(screen.layout.rightColumn.col, 80);
    expect(screen.layout.width, 120); // terminal width, unchanged
    // A terminal resize re-applies the reservation.
    screen.resize(ScreenLayout.fromSize(100, 24, split: false));
    expect(screen.layout.rightColumn.width, 40);
    expect(screen.layout.chat.width, 58);
    screen.setRightColumn(0);
    expect(screen.layout.rightColumn, isEmpty);
    expect(screen.layout.chat.width, 98);
    // A shrink below what the reservation can carry degrades to none
    // (it used to throw from the width clamp) instead of killing the
    // resize handler.
    screen.setRightColumn(40);
    screen.resize(ScreenLayout.fromSize(40, 10, split: false));
    expect(screen.layout.rightColumn, isEmpty);
    expect(screen.layout.chat.width, 38);
    screen.setRightColumn(0);
    screen.resize(ScreenLayout.fromSize(120, 30, split: false));
    expect(screen.layout.chat.width, 118);
    screen.dispose();
  });
}

final class _Io implements Stdio {
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 120;
  @override
  int get terminalLines => 30;
  @override
  bool get hasTerminal => false;
  @override
  bool get stdinHasTerminal => false;
  @override
  bool get echoMode => false;
  @override
  bool get lineMode => false;
  @override
  void setEchoMode(bool value) {}
  @override
  void setLineMode(bool value) {}
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}
