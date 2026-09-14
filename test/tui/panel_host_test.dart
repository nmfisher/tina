import 'package:test/test.dart';
import 'package:tina/tui/panel_host.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina_console/tina_console.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/fake_terminal_geometry.dart';

/// No agent, session, transcript, or workflow is needed to host content.
class TestContent implements PanelContent {
  final fits = <Rect>[];
  int detaches = 0;
  @override
  bool isDetached = true;
  @override
  BackendSurface? get surface => null;
  @override
  void fit(Rect interior, {required bool reserveInputRow}) =>
      fits.add(interior);
  @override
  void attach() => isDetached = false;
  @override
  void detach() {
    isDetached = true;
    detaches++;
  }

  @override
  void bindSurface(BackendSurface? surface) {}
  @override
  void repaint() {}
}

void main() {
  late Screen screen;
  late LineEditor editor;
  late FocusManager focus;
  late PanelManager manager;
  late PanelHost host;
  late Map<PanelFrame, PanelContent> contents;
  var failLayout = false;

  setUp(() {
    screen = Screen(
      io: FakeStdio()..columns = 120,
      layout: ScreenLayout.fromSize(120, 24),
      ansi: AnsiCapable.yes,
    );
    editor = LineEditor(screen: screen);
    focus = FocusManager();
    final primary = PanelFrame(
      screen: screen,
      label: 'chat',
      conversationId: 'chat',
    );
    focus
      ..register(primary)
      ..home = primary;
    manager = PanelManager(
      screen: screen,
      focusManager: focus,
      editor: editor,
      primaryFrame: primary,
      terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
      menuBarEnabled: false,
      tree: SpawnTree(rootId: 'chat'),
    );
    contents = {};
    failLayout = false;
    host = PanelHost(
      panelManager: manager,
      bindContent: ({required frame, required content}) {
        contents[frame] = content;
        manager.addFrame(frame);
      },
      unbindContent: (frame) => contents.remove(frame)?.detach(),
      refreshLayout: () {
        if (failLayout) throw StateError('layout failed');
        manager.applyScreenLayout(
          split: manager.hasSpawnedFrames,
          drawInfoFrame: !manager.hasSpawnedFrames,
        );
        manager.layout();
        for (final entry in contents.entries) {
          entry.value.fit(entry.key.contentInterior, reserveInputRow: false);
          entry.value.attach();
        }
      },
    );
  });

  tearDown(() async {
    host.dispose();
    manager.dispose();
    editor.close();
  });

  PanelSpec spec([String id = 'custom']) =>
      (id: id, label: 'Custom content', placement: PanelPlacement.sideColumn);

  test('hosts arbitrary content synchronously without stealing focus', () {
    final content = TestContent();
    final events = <InputEvent>[];
    final opened = host.openPanel(
      spec(),
      content: content,
      inputMode: PanelInputMode.exclusive,
      onInput: (event) {
        events.add(event);
        return true;
      },
    );
    expect(opened.content, same(content));
    expect(content.fits.single.isEmpty, isFalse);
    expect(content.isDetached, isFalse);
    expect(opened.frame.reservesInput, isFalse);
    expect(focus.focused, same(manager.primaryFrame));
    opened.frame.handleEvent(CharInput('hello'));
    expect(events, [CharInput('hello')]);
  });

  test('default read-only content never sends text to the chat editor', () {
    final opened = host.openPanel(spec(), content: TestContent());
    for (final event in <InputEvent>[
      CharInput('a'),
      PasteInput('paste'),
      ControlKey(ControlCode.enter),
      ControlKey(ControlCode.backspace),
      EditingKey(EditingAction.delete),
    ]) {
      expect(opened.frame.handleEvent(event), isTrue);
    }
  });

  test('duplicate IDs are rejected without changing the original panel', () {
    final first = host.openPanel(spec(), content: TestContent());
    expect(
      () => host.openPanel(spec(), content: TestContent()),
      throwsStateError,
    );
    expect(
      () => host.openPanel(spec('chat'), content: TestContent()),
      throwsStateError,
    );
    expect(host.panelFor('custom'), same(first));
    expect(manager.spawnedFrames, hasLength(1));
  });

  test(
    'close releases hooks once and an old handle cannot close a replacement',
    () {
      var disposed = 0;
      final content = TestContent();
      final first = host.openPanel(
        spec(),
        content: content,
        onInput: (_) => true,
        onDispose: () => disposed++,
      );
      host.closePanel(first);
      host.closePanel(first);
      first.setFinished();
      expect(first.isClosed, isTrue);
      expect(disposed, 1);
      expect(content.detaches, 1);
      expect(first.frame.onPanelKey, isNull);
      expect(manager.tree.parentOf.containsKey('custom'), isFalse);
      final second = host.openPanel(spec(), content: TestContent());
      host.closePanel(first);
      expect(host.panelFor('custom'), same(second));
    },
  );

  test('failed layout rolls back bindings, identity, and owned resources', () {
    var disposed = 0;
    final content = TestContent();
    failLayout = true;
    expect(
      () =>
          host.openPanel(spec(), content: content, onDispose: () => disposed++),
      throwsStateError,
    );
    expect(host.panelFor('custom'), isNull);
    expect(contents, isEmpty);
    expect(manager.spawnedFrames, isEmpty);
    expect(manager.tree.parentOf.containsKey('custom'), isFalse);
    expect(disposed, 1);
    failLayout = false;
    host.openPanel(spec(), content: TestContent());
  });

  test('shutdown releases all views even when one dispose callback throws', () {
    final first = host.openPanel(
      spec('a'),
      content: TestContent(),
      onDispose: () => throw StateError('dispose failed'),
    );
    final second = host.openPanel(spec('b'), content: TestContent());
    expect(host.dispose, throwsStateError);
    expect(first.isClosed && second.isClosed, isTrue);
    expect(manager.spawnedFrames, isEmpty);
    expect(contents, isEmpty);
    expect(
      () => host.openPanel(spec(), content: TestContent()),
      throwsStateError,
    );
    host.dispose();
  });
}
