import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

class Probe extends ModalSurface implements ConsoleContribution {
  Probe({this.fail = false});
  final bool fail;
  late ConsoleContext context;
  int releases = 0, keys = 0;
  @override
  bool get isActive => true;
  @override
  bool handleEvent(InputEvent event) {
    keys++;
    return false;
  }

  @override
  void attachConsole(ConsoleContext context) {
    this.context = context;
    context.own(() => releases++);
    context.settings
        .registerSection(id: 'acme/probe', title: 'Probe', build: () => []);
    context.bindPrompt(() => 'probe > ');
    context.bindStatus(() => [
          RenderLine(runs: [RenderRun('probe status', '')])
        ]);
    context.bindShortcut((_) {
      keys++;
      return false;
    });
    context.addModal(this);
    if (fail) throw StateError('attach failed');
  }

  @override
  void detachConsole() {
    if (fail) throw StateError('detach also failed');
    // Deliberately omit manual unregistration: the attachment owns it.
  }

  @override
  void repaintConsole() {}
}

void main() {
  late FakeIo io;
  late Screen screen;
  late LineEditor editor;
  late ConsoleContext context;
  late Directory directory;
  late String config;
  setUp(() {
    io = FakeIo();
    screen = fakeScreen(io);
    editor = LineEditor(screen: screen);
    context = ConsoleContext(screen: screen, editor: editor);
    directory = Directory.systemTemp.createTempSync('settings-contributions-');
    config = '${directory.path}/config';
    File(config).writeAsStringSync(
        '[default]\nmodel = "fixture"\n[plugins]\nenabled = []\n');
  });
  tearDown(() {
    editor.close();
    screen.dispose();
    io.closeInput();
    directory.deleteSync(recursive: true);
  });

  test('failed attachment rolls back all bindings even if detach throws',
      () async {
    final bad = Probe(fail: true);
    expect(
        () => ConsoleAttachment.attach(bad, context),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'attach failed')));
    expect(context.settings.sections, isEmpty);
    expect(editor.promptBuilder, isNull);
    expect(bad.releases, 1);
    expect(
        () => bad.context.settings
            .registerSection(id: 'acme/late', title: 'Late', build: () => []),
        throwsStateError);
    final line = editor.readLine('> ');
    await Future<void>.delayed(Duration.zero);
    io.feedBytes('hello\r'.codeUnits);
    expect(await line, 'hello');
    expect(bad.keys, 0);
    final good = Probe();
    final attachment = ConsoleAttachment.attach(good, context);
    expect(context.settings.sections.single.id, 'acme/probe');
    attachment.dispose();
    attachment.dispose();
    expect(good.releases, 1);
    expect(context.settings.sections, isEmpty);
    expect(editor.promptBuilder, isNull);
  });

  test(
      'registration orders sections and rejects duplicates without replacing owners',
      () {
    final remove = context.settings
        .registerSection(id: 'acme/z', title: 'Z', order: 1, build: () => []);
    context.settings.registerSection(id: 'acme/a', title: 'A', build: () => []);
    expect(context.settings.sections.map((s) => s.id), ['acme/z', 'acme/a']);
    expect(
        () => context.settings.registerSection(
            id: 'acme/z', title: 'Replacement', build: () => []),
        throwsStateError);
    remove();
    remove();
    expect(context.settings.sections.single.id, 'acme/a');
  });

  test(
      'settings renders plugin controls and invokes their callbacks without saving config',
      () async {
    var enabled = false, text = 'old', choice = 'one', calls = 0;
    final original = File(config).readAsStringSync();
    context.settings.registerSection(
        id: 'acme/example',
        title: 'Example',
        build: () => [
              SettingToggle(
                  id: 'enabled',
                  label: 'Enabled',
                  read: () => enabled,
                  change: (v) => enabled = v),
              SettingText(
                  id: 'text',
                  label: 'Text',
                  read: () => text,
                  change: (v) => text = v),
              SettingChoice(
                  id: 'choice',
                  label: 'Choice',
                  read: () => choice,
                  options: ['one', 'two'],
                  change: (v) => choice = v),
              SettingAction(
                  id: 'action', label: 'Run action', invoke: () => calls++),
            ]);
    final enter = ControlKey(ControlCode.enter),
        down = ArrowKey(ArrowDirection.down);
    final keys = <InputEvent>[
      CharInput('Example'), enter, CharInput(' '), // section, toggle
      down, enter, EditingKey(EditingAction.killToStart), CharInput('new'),
      enter,
      down, down, enter, down, enter, // choice
      down, down, down, enter, // action
      EscapeKey(), EscapeKey(),
    ];
    final panel =
        SettingsPanel(screen, editor, readEvent: () async => keys.removeAt(0));
    expect(await panel.run(path: config, sections: context.settings), false);
    expect(keys, isEmpty);
    expect(enabled, true);
    expect(text, 'new');
    expect(choice, 'two');
    expect(calls, 1);
    expect(File(config).readAsStringSync(), original);
  });

  test('open settings reacts to registration and unloading an active editor',
      () async {
    final events = StreamController<InputEvent>();
    final iterator = StreamIterator(events.stream);
    var changed = 0;
    final panel = SettingsPanel(screen, editor, readEvent: () async {
      expect(await iterator.moveNext(), true);
      return iterator.current;
    });
    final result = panel.run(path: config, sections: context.settings);
    await Future<void>.delayed(Duration.zero);
    io.written.clear();
    final remove = context.settings.registerSection(
        id: 'acme/live',
        title: 'Live section',
        build: () => [
              SettingText(
                  id: 'text',
                  label: 'Edit live value',
                  read: () => '',
                  change: (_) => changed++),
            ]);
    await Future<void>.delayed(Duration.zero);
    // Contributions are searchable without expanding the five-category home.
    events.add(CharInput('Live section'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(io.written.toString(), contains('Live section'));
    events.add(ControlKey(ControlCode.enter));
    events.add(ControlKey(ControlCode.enter));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(io.written.toString(), contains('Edit live value'));
    io.written.clear();
    remove();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(io.written.toString(), contains('Settings'));
    events.add(EscapeKey());
    expect(await result, false);
    expect(changed, 0);
    await iterator.cancel();
    await events.close();
  });
}
