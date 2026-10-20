import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_tasks/tina_tasks.dart';
import 'package:tina_tasks_tui/tina_tasks_tui.dart';

final class Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();

  void feed(String value) => input.add(value.codeUnits);

  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class _FakeTasks implements TaskObservation {
  _FakeTasks(this.state);
  @override
  TaskState state;
  final _listeners = <void Function()>[];
  @override
  String? get unavailableReason => null;

  void update(TaskState next) {
    state = next;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  @override
  void Function() listen(void Function() changed) {
    _listeners.add(changed);
    return () => _listeners.remove(changed);
  }
}

final class _Presentation {
  _Presentation(TaskObservation observation) {
    home.setOuter(screen.chat.bounds);
    focus.register(home);
    focus.home = home;
    editor.focusManager = focus;
    view = TaskOverviewView(observation);
    attachment = ConsoleAttachment.attach(
      view,
      ConsoleContext(screen: screen, editor: editor),
    );
  }
  final io = Io();
  late final screen = Screen(
    io: io,
    ansi: AnsiCapable.yes,
    layout: ScreenLayout.fromSize(100, 24, split: false),
  );
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  final focus = FocusManager();
  late final home = PanelFrame(
    screen: screen,
    label: 'chat',
    conversationId: 'test',
    border: false,
  );
  late final TaskOverviewView view;
  late final ConsoleAttachment attachment;
  String get visible {
    final terminal = VirtualTerminal(width: 100, height: 24)
      ..feed(io.output.toString());
    return List.generate(24, terminal.rowText).join('\n');
  }

  void dispose() {
    attachment.dispose();
    home.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  }
}

void main() {
  late _FakeTasks tasks;
  late _Presentation p;

  TaskEntryItem item(String id, String text, String state) =>
      TaskEntryItem(id: id, text: text, state: state);

  setUp(() {
    tasks = _FakeTasks(TaskState(items: []));
    p = _Presentation(tasks);
  });

  tearDown(() => p.dispose());

  test('renders the active and next tasks', () {
    tasks.update(TaskState(items: [
      item('t1', 'refactor the parser', 'in_progress'),
      item('t2', 'write more tests', 'pending'),
      item('t3', 'release notes', 'pending'),
    ]));
    final visible = p.visible;
    expect(visible, contains('tasks'));
    expect(visible, contains('t1'));
    expect(visible, contains('refactor the parser'));
    expect(visible, contains('t2'));
    expect(visible, contains('write more tests'));
    expect(visible, contains('2 pending'));
    expect(visible, contains('3 total'));
  });

  test('shows a placeholder when nothing is active but tasks are pending',
      () {
    tasks.update(TaskState(items: [
      item('t1', 'first', 'pending'),
      item('t2', 'second', 'pending'),
    ]));
    final visible = p.visible;
    expect(visible, contains('no active task'));
    expect(visible, contains('first'));
    expect(visible, contains('2 pending'));
  });

  test('hides the panel when the queue is empty', () {
    tasks.update(TaskState(items: []));
    expect(p.visible, isNot(contains('tasks')));
  });

  test('repaints on task state changes', () async {
    tasks.update(TaskState(items: [
      item('t1', 'active work', 'in_progress'),
    ]));
    expect(p.visible, contains('active work'));

    tasks.update(TaskState(items: [
      item('t1', 'active work', 'done'),
      item('t2', 'next work', 'pending'),
    ]));
    await Future<void>.microtask(() {});
    final visible = p.visible;
    expect(visible, contains('no active task'));
    expect(visible, contains('next work'));
  });
}
