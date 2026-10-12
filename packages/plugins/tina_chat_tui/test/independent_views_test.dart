import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show Terminal;
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'console_test.dart' show Io;

final class _Updates implements UpdateStatusSource {
  final stream = StreamController<void>.broadcast(sync: true);
  @override
  String get currentVersion => '1.0.0';
  @override
  UpdateStatus status = const UpdateStatus(UpdatePhase.current);
  @override
  Stream<void> get changes => stream.stream;
  @override
  Future<void> checkInBackground() async {}
}

final class _Client {
  final io = Io();
  late final screen =
      Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  late final context = ConsoleContext(screen: screen, editor: editor);
  void dispose() {
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  }
}

void main() {
  test(
      'model pickers own their filters and detach cannot switch the shared model',
      () async {
    var model = 'acme/one';
    final controls = SessionControlsPlugin(
        terminal: _Terminal(),
        currentModel: () => model,
        switchModel: (value) => model = value,
        modelCatalog: () =>
            const ModelCatalog(models: ['acme/one', 'acme/two']));
    final first = _Client(), second = _Client();
    final firstView = SessionControlsView(controls.observation),
        secondView = SessionControlsView(controls.observation);
    final firstAttachment = ConsoleAttachment.attach(firstView, first.context);
    final secondAttachment =
        ConsoleAttachment.attach(secondView, second.context);
    addTearDown(() {
      firstAttachment.dispose();
      secondAttachment.dispose();
      first.dispose();
      second.dispose();
      controls.closeSession();
    });
    final pickFirst = firstView.handleConsoleCommand('model', '')!;
    final pickSecond = secondView.handleConsoleCommand('model', '')!;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    first.io.feed('first filter');
    second.io.feed('second filter');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(first.io.output.toString(), contains('first filter'));
    expect(first.io.output.toString(), isNot(contains('second filter')));
    expect(second.io.output.toString(), contains('second filter'));
    firstAttachment.dispose();
    await pickFirst.timeout(const Duration(seconds: 1));
    expect(model, 'acme/one');
    second.io.feed('\x15two\r');
    await pickSecond.timeout(const Duration(seconds: 1));
    expect(model, 'acme/two');
    expect(controls.observation.recentModels, ['acme/two']);
  });
  test('permission and update status reach both views after one detaches',
      () async {
    final policy = ModePlugin(), updates = _Updates();
    final first = _Client(), second = _Client();
    final firstMode = ConsoleAttachment.attach(
        ModeView(mode: policy.observation), first.context);
    final secondMode = ConsoleAttachment.attach(
        ModeView(mode: policy.observation), second.context);
    final firstUpdate =
        ConsoleAttachment.attach(UpdateView(updates), first.context);
    final secondUpdate =
        ConsoleAttachment.attach(UpdateView(updates), second.context);
    addTearDown(() async {
      firstMode.dispose();
      secondMode.dispose();
      firstUpdate.dispose();
      secondUpdate.dispose();
      first.dispose();
      second.dispose();
      policy.closeSession();
      await updates.stream.close();
    });
    policy.mode = PermissionMode.auto;
    expect(first.io.output.toString(), contains('mode: auto'));
    expect(second.io.output.toString(), contains('mode: auto'));
    final releaseBroken = policy.observation
        .listen((_) => throw StateError('broken status renderer'));
    addTearDown(releaseBroken);
    firstMode.dispose();
    firstUpdate.dispose();
    final detachedOutput = first.io.output.toString();
    policy.mode = PermissionMode.readOnly;
    updates.status = const UpdateStatus(UpdatePhase.available, tag: 'v1.0.1');
    updates.stream.add(null);
    expect(first.io.output.toString(), detachedOutput);
    expect(second.io.output.toString(), contains('mode: read-only'));
    expect(second.io.output.toString(), contains('v1.0.1'));
    final replacement = ConsoleAttachment.attach(
        ModeView(mode: policy.observation), first.context);
    expect(first.io.output.toString(), contains('mode: read-only'));
    replacement.dispose();
  });
}

final class _Terminal implements Terminal {
  @override
  Future<String> ask(String prompt) async => '';
  @override
  void writeln([String? line]) {}
}
