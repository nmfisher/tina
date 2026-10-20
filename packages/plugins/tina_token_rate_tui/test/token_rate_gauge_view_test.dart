import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_chat/observation.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_token_rate_tui/tina_token_rate_tui.dart';

final class _FakeSession implements SessionObservation {
  bool running = true;
  final _listeners = <void Function(SessionObservationEvent)>[];
  final _changes = <void Function()>[];

  @override
  String? get model => 'model';
  @override
  Map<String, Object?> get snapshot => const {};
  @override
  ToolDescription? describe(ToolUse call) => null;

  @override
  void Function() listen(void Function(SessionObservationEvent) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  @override
  void Function() listenChanges(void Function() listener) {
    _changes.add(listener);
    return () => _changes.remove(listener);
  }

  void emit(SessionObservationEvent event) {
    for (final listener in List<Function>.of(_listeners)) {
      listener(event);
    }
  }

  void setRunning(bool value) {
    running = value;
    for (final listener in List<Function>.of(_changes)) {
      listener();
    }
  }
}

final class _FakeChat implements ChatObservation {
  _FakeChat(this.events);
  @override
  final SessionObservation events;
  @override
  bool get includesSessionNotices => true;
  @override
  String get model => 'model';
  @override
  String? get sessionId => 's';
  @override
  int get tokenCap => 0;
  @override
  int? get sessionTokens => null;
  @override
  int get sessionEstimatedTokens => 0;
  @override
  bool get showSessionId => true;
  @override
  bool get terminalAlertsEnabled => true;
}

final class _Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 100;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class _Presentation {
  _Presentation(ChatObservation chat) {
    home.setOuter(screen.chat.bounds);
    focus.register(home);
    focus.home = home;
    editor.focusManager = focus;
    view = TokenRateGaugeView(chat, now: () => now);
    attachment = ConsoleAttachment.attach(
      view,
      ConsoleContext(screen: screen, editor: editor),
    );
  }

  var now = DateTime.fromMillisecondsSinceEpoch(0);
  final _io = _Io();
  late final screen = Screen(
    io: _io,
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
  late final TokenRateGaugeView view;
  late final ConsoleAttachment attachment;

  String get visible => _io.output.toString();
  void clearOutput() => _io.output.clear();

  void dispose() {
    attachment.dispose();
    home.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(_io.input.close());
  }
}

void main() {
  late _FakeSession events;
  late _Presentation p;

  setUp(() {
    events = _FakeSession();
    p = _Presentation(_FakeChat(events));
  });

  tearDown(() => p.dispose());

  test('renders a live token rate while generating', () {
    expect(p.visible, isNot(contains('tok/s')));

    // Baseline at 0 tokens, then stream 200 chars (= 50 estimated tokens) and
    // let one second elapse: 50 tok/s.
    p.view.poll();
    events.emit(ObservedModel(SawText(List.filled(200, 'x').join())));
    p.now = p.now.add(Duration(seconds: 1));
    p.view.poll();

    expect(p.visible, contains('◔ 50 tok/s'));
  });

  test('hides the gauge when the session is idle', () {
    p.view.poll();
    events.emit(ObservedModel(SawText(List.filled(200, 'x').join())));
    p.now = p.now.add(Duration(seconds: 1));
    p.view.poll();
    expect(p.visible, contains('50 tok/s'));

    events.setRunning(false);
    p.clearOutput();
    p.view.repaintConsole();
    expect(p.visible, isNot(contains('tok/s')));
  });

  test('hides the gauge when the rate is negligible', () {
    // Only 2 chars (0.5 estimated tokens) over a second: below the 1 tok/s
    // floor, so the gauge stays hidden.
    p.view.poll();
    events.emit(ObservedModel(SawText('ab')));
    p.now = p.now.add(Duration(seconds: 1));
    p.view.poll();
    expect(p.visible, isNot(contains('tok/s')));
  });
}
