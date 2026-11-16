import 'dart:async';

import 'package:tina_console/tina_console.dart';

/// Side-column geometry probe: drives the real SideColumnLayout over a
/// real Screen at three terminal widths — wide, at the threshold's low
/// end, and below it — with all three panels open as the app opens
/// them (classifier 8 rows, plans 6, channel everything left). Prints
/// the mode, the column's width and each panel's slot so the layout
/// rule is observable without a terminal:
///
///     dart run tool/side_column_probe.dart
Future<void> main() async {
  for (final width in [140, 100, 96, 80]) {    final screen = Screen(
      io: _Io(width),
      ansi: AnsiCapable.yes,
      layout: ScreenLayout.fromSize(width, 40, split: false),
    );
    final column = SideColumnLayout(
        layout: () => screen.layout, setReservation: screen.setRightColumn);
    SideColumnPanel open(int rank, int height) {
      late SideColumnPanel panel;
      panel = column.register(() => panel.requestSize(height: height),
          rank: rank);
      panel.requestSize(height: height);
      return panel;
    }

    final classifier = open(SideColumnRank.classifier, 8);
    final plans = open(SideColumnRank.plans, 6);
    final channel = open(SideColumnRank.channel, 10000);
    await Future<void>.delayed(Duration.zero);

    final area = screen.layout.rightColumn;
    print('terminal $width: '
        '${column.active ? 'column' : 'stacked fallback'}'
        '${area.isEmpty ? '' : ' (width ${area.width})'}, '
        'chat width ${screen.layout.chat.width}');
    print('  classifier ${classifier.bounds}');
    print('  plans      ${plans.bounds}');
    print('  channel    ${channel.bounds}');
    screen.dispose();
  }
}

final class _Io implements Stdio {
  _Io(this.width);
  final int width;
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => width;
  @override
  int get terminalLines => 40;
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
