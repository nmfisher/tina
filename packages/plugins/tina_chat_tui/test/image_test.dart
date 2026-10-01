import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'console_test.dart' show Io;

const image = ImageBlock(
    mimeType: 'image/png',
    data:
        'iVBORw0KGgoAAAANSUhEUgAAABgAAAAgCAYAAAAIXrg4AAAAJ0lEQVR4nO3NsQ0AAAjAoP7/tF7hYMLATFNzKYFAIBAIBAKBQPAlWMuz+kyFM+vqAAAAAElFTkSuQmCC');

class Images extends AnsiBackend implements RetainedImageBackend {
  Images(Io io) : super(io: io, ansi: AnsiCapable.yes);
  @override
  ImageCellSize imageCellSize = ImageCellSize.halfBlock;
  final visible = <Object, List<ImagePlacement>>{};
  @override
  bool updateImages(Object owner, List<ImagePlacement> images,
      {BackendSurface? targetSurface}) {
    visible[owner] = List.of(images);
    return true;
  }

  @override
  void clearImages(Object owner) => visible.remove(owner);
}

void main() {
  late Io io;
  late Images backend;
  late Screen screen;
  late LineEditor editor;
  late ChatTuiPlugin chat;
  setUp(() {
    io = Io();
    backend = Images(io);
    screen = Screen.withBackend(
        io: io,
        backend: backend,
        layout: ScreenLayout.fromSize(40, 24, split: false));
    editor = LineEditor(screen: screen);
    chat = ChatTuiPlugin(model: 'test')
      ..attachConsole(ConsoleContext(screen: screen, editor: editor));
  });
  tearDown(() {
    chat.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  test('user and assistant attachments reserve rows and keep their captions',
      () {
    for (final role in [Role.user, Role.assistant]) {
      chat.entry(
          MessageAppendedEntry(
              turnId: role.name,
              message: Message(
                  role: role, content: [const TextBlock('Screenshot'), image])),
          LogEvent.appended);
    }
    expect(chat.blocks.where((b) => b.subject.startsWith('Image ·')),
        hasLength(2));
    expect(screen.chat.snapshotLines().join('\n'), contains('24×32'));
    final rendered = backend.visible[screen.chat]!;
    expect(rendered, isNotEmpty);
    expect(rendered.last.image.rows, 16);
    expect(rendered.last.column, screen.chat.bounds.col + 7);
    final count = chat.blocks.length;
    chat.repaintConsole();
    expect(chat.blocks, hasLength(count));
  });

  test('live tool images render once and replay restores the same layout', () {
    const call = ToolUse(id: 'shot', name: 'screenshot', input: {});
    chat.observe(const ToolStarted(call));
    chat.observe(
        const ToolFinished(call, ToolResult('Captured', images: [image])));
    final resultEntry = MessageAppendedEntry(
        turnId: 'shot',
        message: const Message(role: Role.user, content: [
          ToolResultBlock(
              toolUseId: 'shot', content: 'Captured', images: [image])
        ]));
    chat.entry(resultEntry, LogEvent.appended);
    expect(chat.blocks.where((b) => b.subject.startsWith('Image ·')),
        hasLength(1));
    final before = screen.chat.snapshotLines();
    chat.closeSession();
    chat = ChatTuiPlugin(model: 'test');
    chat.entry(
        MessageAppendedEntry(
            turnId: 'shot',
            message: const Message(role: Role.assistant, content: [
              ToolUseBlock(id: 'shot', name: 'screenshot', input: {})
            ])),
        LogEvent.replay);
    chat.entry(resultEntry, LogEvent.replay);
    chat.attachConsole(ConsoleContext(screen: screen, editor: editor));
    expect(chat.blocks.where((b) => b.subject.startsWith('Image ·')),
        hasLength(1));
    expect(backend.visible[screen.chat], isNotEmpty);
    expect(screen.chat.contentRows, before.length);
  });

  test('image fitting follows height, width and blitter changes', () {
    chat.entry(
        MessageAppendedEntry(
            turnId: 'shot',
            message: const Message(role: Role.assistant, content: [image])),
        LogEvent.appended);
    final original = backend.visible[screen.chat]!.single.image;
    screen.resize(ScreenLayout.fromSize(16, 10, split: false));
    chat.repaintConsole();
    final small = backend.visible[screen.chat]!.single;
    expect(
        small.image.columns, lessThanOrEqualTo(screen.chat.bounds.width - 7));
    expect(small.image.rows, lessThan(original.rows));
    backend.imageCellSize = const ImageCellSize(8, 16);
    chat.repaintConsole();
    final pixels = backend.visible[screen.chat]!.single.image;
    expect(pixels.cells, backend.imageCellSize);
    expect(pixels.rows, 2);
  });

  test('ANSI keeps a readable caption and bad images never stop output', () {
    chat.closeSession();
    final ansiScreen =
        Screen(io: io, layout: ScreenLayout.fromSize(40, 24, split: false));
    final ansiEditor = LineEditor(screen: ansiScreen);
    addTearDown(() {
      ansiEditor.close(reportLatency: false);
      ansiScreen.dispose();
    });
    chat = ChatTuiPlugin(model: 'test')
      ..attachConsole(ConsoleContext(screen: ansiScreen, editor: ansiEditor));
    chat.entry(
        MessageAppendedEntry(
            turnId: 'shot',
            message: const Message(role: Role.assistant, content: [
              image,
              ImageBlock(data: 'bad base64!', mimeType: 'image/png'),
              TextBlock('Still working')
            ])),
        LogEvent.appended);
    expect(ansiScreen.chat.contentRows, lessThan(10));
    final text = ansiScreen.chat.snapshotLines().join('\n');
    expect(text, contains('Image · image/png · 24×32'));
    expect(text, contains('Image unavailable'));
    expect(text, contains('Still working'));
  });
}
