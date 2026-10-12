import 'package:test/test.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_cwd_tui/tina_cwd_tui.dart';

class _Io implements Stdio {
  final output = StringBuffer();
  @override
  int get terminalColumns => 120;
  @override
  bool get hasTerminal => false;
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
  @override
  void write(String text) => output.write(text);
}

class _Panels implements ConsolePanels {
  @override
  Future<void> spawn([String? model]) async {}
  @override
  Future<void> closeFocused() async {}
  @override
  List<String> describe() => [];
}

void main() {
  late _Io io;
  late Screen screen;
  late LineEditor editor;
  late ConsoleContext context;
  late VirtualTerminal terminal;

  setUp(() {
    io = _Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(120, 24, split: false));
    editor = LineEditor(screen: screen);
    context = ConsoleContext(screen: screen, editor: editor);
    terminal = VirtualTerminal(width: 120, height: 24);
  });
  tearDown(() {
    editor.close(reportLatency: false);
    screen.dispose();
  });
  String status() {
    terminal.feed(io.output.toString());
    io.output.clear();
    return terminal.rowText(23);
  }

  test('attach, repaint and detach preserve other status contributions', () {
    context.bindStatus(
        () => [
              const RenderLine(runs: [RenderRun('v1.0.0', null)])
            ],
        priority: 10);
    final view = CwdView('/work/project');
    final attachment = ConsoleAttachment.attach(view, context);
    expect(status(), contains('cwd: /work/project'));
    view.repaintConsole();
    expect('cwd:'.allMatches(status()), hasLength(1));
    attachment.dispose();
    final row = status();
    expect(row, contains('v1.0.0'));
    expect(row, isNot(contains('cwd:')));
  });

  test('long Unicode paths retain their end and expand on resize', () {
    final path = '/work/${'long/' * 6}项目';
    final view = CwdView(path)..attachConsole(context);
    addTearDown(view.detachConsole);
    expect(status(), contains('cwd: …'));
    expect(status(), contains('项目'));
    screen.resize(ScreenLayout.fromSize(180, 24, split: false));
    terminal = VirtualTerminal(width: 180, height: 24);
    view.repaintConsole();
    expect(status(), contains('cwd: $path'));
    expect(terminal.scrollCount, 0);
  });

  test('status follows the active session and releases bindings independently',
      () {
    var active = 0;
    ConsoleContext scope(int index) => context.forView(
        chat: screen.chat,
        isActive: () => active == index,
        activate: () => active = index,
        panels: _Panels());
    final first = ConsoleAttachment.attach(CwdView('/work/first'), scope(0));
    final second = ConsoleAttachment.attach(CwdView('/work/second'), scope(1));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    expect(status(), contains('cwd: /work/first'));
    active = 1;
    context.refreshStatus();
    final row = status();
    expect(row, contains('cwd: /work/second'));
    expect(row, isNot(contains('/work/first')));
    first.dispose();
    expect(status(), contains('cwd: /work/second'));
  });
}
