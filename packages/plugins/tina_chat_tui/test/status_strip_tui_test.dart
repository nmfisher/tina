import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';

class Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}

/// Loads `tina/status-strip-tui` on a console whose producers are already
/// bound, then unloads it, verifying takeover and restore of the strip slot.
void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late ConsoleContext context;
  late VirtualTerminal vt;

  String stripRow() => vt.rowText(23);

  setUp(() {
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    context = ConsoleContext(screen: screen, editor: editor);
    vt = VirtualTerminal(width: 80, height: 24)..feed(io.output.toString());
    io.output.clear();
    // Producers bound BEFORE the container, so takeover must inherit them.
    context.bindStatus(
        () => [
              const RenderLine(runs: [
                RenderRun('v0.9.0', null),
                RenderRun(' · update ⬆ v0.9.1', '33')
              ])
            ],
        priority: 10);
    context.bindStatus(
        () => [
              const RenderLine(align: StatusAlign.right, runs: [
                RenderRun('Σ 12,345 / 30,000 · 41%', null),
              ]),
            ],
        priority: 100);
  });

  tearDown(() {
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  test('takeover arranges inherited producers under width pressure', () {
    final plugin = StatusStripTuiPlugin()..attachConsole(context);
    addTearDown(plugin.closeSession);
    vt.feed(io.output.toString());
    final row = stripRow();
    expect(row, contains('v0.9.0'));
    expect(row.trimRight().endsWith('41%'), isTrue,
        reason: 'the right slot survives width pressure');
  });

  test('a narrow strip drops the left line before the right slot', () {
    final plugin = StatusStripTuiPlugin()..attachConsole(context);
    addTearDown(plugin.closeSession);
    io.output.clear();
    screen.resize(ScreenLayout.fromSize(40, 24, split: false));
    plugin.repaintConsole();
    vt = VirtualTerminal(width: 40, height: 24)..feed(io.output.toString());
    final row = stripRow();
    expect(row, isNot(contains('update')),
        reason: 'the left producer dies first under width pressure');
    expect(row.trimRight().endsWith('41%'), isTrue);
  });

  test('detaching restores the default arrangement', () {
    final plugin = StatusStripTuiPlugin()..attachConsole(context);
    vt.feed(io.output.toString());
    expect(stripRow(), contains('v0.9.0'));
    plugin.detachConsole();
    io.output.clear();
    vt.feed(io.output.toString());
    // The default layout keeps every line; the painter clips the left group
    // before the right-anchored text.
    final row = stripRow();
    expect(row, contains('update'));
    expect(row.trimRight().endsWith('41%'), isTrue);
    expect(row.length, lessThanOrEqualTo(80));
  });

  test('arrangement tracks terminal width on resize', () {
    final plugin = StatusStripTuiPlugin()..attachConsole(context);
    addTearDown(plugin.closeSession);
    io.output.clear();
    screen.resize(ScreenLayout.fromSize(120, 24, split: false));
    plugin.repaintConsole();
    vt = VirtualTerminal(width: 120, height: 24)..feed(io.output.toString());
    final row = stripRow();
    expect(row, contains('v0.9.0 · update ⬆ v0.9.1'));
    expect(row, contains('Σ 12,345 / 30,000 · 41%'));
  });

  test('a background view attach does not rearrange the focused strip', () {
    // The plugin was never attached to the active root here: attaching it to
    // a background view, and every later call, must be a no-op.
    final plugin = StatusStripTuiPlugin();
    io.output.clear();
    final background = context.forView(
        chat: screen.chat,
        isActive: () => false,
        activate: () {},
        panels: _EmptyPanels());
    plugin.attachConsole(background);
    expect(io.output.toString(), isEmpty,
        reason: 'inactive attach must be a no-op');
    plugin.repaintConsole();
    expect(io.output.toString(), isEmpty);
    plugin.detachConsole();
    expect(io.output.toString(), isEmpty);
  });
}

class _EmptyPanels implements ConsolePanels {
  @override
  Future<void> spawn([String? model]) async {}
  @override
  Future<void> closeFocused() async {}
  @override
  List<String> describe() => const [];
}
