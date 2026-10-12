import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/src/question_view.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

final class _Io implements Stdio {
  final input = StreamController<List<int>>.broadcast(sync: true);
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String text) => output.write(text);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class _View {
  _View(SessionQuestions questions) : client = questions.connect() {
    screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    context = ConsoleContext(screen: screen, editor: editor);
    view = QuestionView(client);
    attach();
  }
  final io = _Io();
  final QuestionClient client;
  late final Screen screen;
  late final LineEditor editor;
  late final ConsoleContext context;
  late final QuestionView view;
  late ConsoleAttachment attachment;
  void attach() => attachment = ConsoleAttachment.attach(view, context);
  Future<void> type(String text) async {
    io.input.add(text.codeUnits);
    await tick();
  }

  Future<void> close() async {
    attachment.dispose();
    client.close();
    await tick();
    editor.close(reportLatency: false);
    screen.dispose();
    await io.input.close();
  }
}

final class _Panels implements ConsolePanels {
  @override
  Future<void> spawn([String? model]) async {}
  @override
  Future<void> closeFocused() async {}
  @override
  List<String> describe() => [];
}

void main() {
  late SessionQuestions questions;
  setUp(() => questions = SessionQuestions());
  tearDown(() => questions.close());

  test('two views keep separate drafts and the first answer closes both',
      () async {
    final first = _View(questions), second = _View(questions);
    addTearDown(first.close);
    addTearDown(second.close);
    final result = questions.ask('Which branch?');
    await tick();
    expect(first.editor.isReadingKey, isTrue);
    expect(second.editor.isReadingKey, isTrue);
    await first.type('first draft');
    await second.type('second draft');
    await first.type('\r');
    expect((await result).text, 'first draft');
    expect(first.editor.isReadingKey, isFalse);
    expect(second.editor.isReadingKey, isFalse);
    expect(second.client.pending, isEmpty);
  });

  test('detach releases input immediately and reattach retains the question',
      () async {
    final view = _View(questions);
    addTearDown(view.close);
    final result = questions.ask('Still here?');
    await tick();
    final id = view.client.pending.single.id;
    await view.type('discard this draft');
    view.attachment.dispose();
    expect(view.editor.isReadingKey, isFalse);
    expect(view.client.pending.single.id, id);
    // Reattach without waiting for the old dialog continuation to unwind.
    view.attach();
    await tick();
    expect(view.editor.isReadingKey, isTrue);
    await view.type('fresh\r');
    expect((await result).text, 'fresh');
  });

  test('a queued question answered elsewhere never activates its panel',
      () async {
    final view = _View(questions);
    addTearDown(view.close);
    view.attachment.dispose();
    var activations = 0;
    final panel = view.context.forView(
        chat: view.screen.chat,
        isActive: () => false,
        activate: () => activations++,
        panels: _Panels());
    view.attachment = ConsoleAttachment.attach(view.view, panel);
    final release = Completer<void>();
    final modal = view.context.interact(() => release.future);
    final result = questions.ask('Queued behind settings');
    await tick();
    expect(view.editor.isReadingKey, isFalse);
    final remote = questions.connect();
    addTearDown(remote.close);
    remote.answer(remote.pending.single.id, 'elsewhere');
    expect((await result).text, 'elsewhere');
    release.complete();
    await modal;
    await tick();
    expect(activations, 0);
    expect(view.editor.isReadingKey, isFalse);
  });

  test('buffered keys cannot answer the next question', () async {
    final view = _View(questions);
    addTearDown(view.close);
    final one = questions.ask('First'), two = questions.ask('Second');
    await tick();
    await view.type('one\raccidental\r');
    expect((await one).text, 'one');
    expect(view.client.pending.single.prompt, 'Second');
    await view.type('two\r');
    expect((await two).text, 'two');
  });

  test('a resized question remains editable and Escape explicitly dismisses it',
      () async {
    final view = _View(questions);
    addTearDown(view.close);
    final result = questions.ask('A prompt ' * 200);
    await tick();
    view.screen.resize(ScreenLayout.fromSize(12, 4));
    view.view.repaintConsole();
    await view.type('\x1b');
    expect((await result).disposition, QuestionDisposition.cancelled);
    expect(view.editor.isReadingKey, isFalse);
  });
}
