import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';

import 'stdio_fake.dart';

const redPng =
    'iVBORw0KGgoAAAANSUhEUgAAABgAAAAgCAYAAAAIXrg4AAAAJ0lEQVR4nO3NsQ0AAAjAoP7/tF7hYMLATFNzKYFAIBAIBAKBQPAlWMuz+kyFM+vqAAAAAElFTkSuQmCC';

class _HeadlessImageBackend extends AnsiBackend {
  _HeadlessImageBackend(FakeStdio io, ImageColorMode mode)
      : super(io: io, ansi: AnsiCapable.yes, imageColor: mode);
}

void main() {
  test('AnsiBackend cell size follows the color mode', () {
    final io = FakeStdio();
    final color = _HeadlessImageBackend(io, ImageColorMode.truecolor);
    expect(color.imageCellSize, ImageCellSize.halfBlock);
    final mono = _HeadlessImageBackend(FakeStdio(), ImageColorMode.mono);
    expect(mono.imageCellSize, const ImageCellSize(1, 1));
  });

  test('updateImages paints half-block cells and clearImages erases them',
      () {
    final io = FakeStdio();
    final backend = _HeadlessImageBackend(io, ImageColorMode.truecolor);
    final raster = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 2, rows: 1, cells: ImageCellSize.halfBlock);
    final painted = backend.updateImages(#owner, [
      ImagePlacement(
          image: raster,
          row: 2,
          column: 3,
          sourceRow: 0,
          rows: raster.rows,
          columns: raster.columns)
    ]);
    expect(painted, isTrue);
    backend.flush();
    final out = io.written.toString();
    expect(out, contains('▀'));
    expect(out, contains('38;2;'));
    backend.clearImages(#owner);
    backend.flush();
    // Erase uses ECH (`\x1b[nX`) over the painted cell extents.
    expect(io.written.toString(), contains(RegExp(r'\x1b\[\d+X')));
  });

  test('mono mode keeps the placeholder degradation', () {
    final io = FakeStdio();
    final backend = _HeadlessImageBackend(io, ImageColorMode.mono);
    final raster = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 2, rows: 1, cells: const ImageCellSize(1, 1));
    backend.updateImages(#owner, [
      ImagePlacement(
          image: raster,
          row: 0,
          column: 0,
          sourceRow: 0,
          rows: raster.rows,
          columns: raster.columns)
    ]);
    backend.flush();
    final out = io.written.toString();
    expect(out, contains('▣'));
    expect(out, isNot(contains('▀')));
  });

  test('indexed mode emits palette SGR, not direct color', () {
    final io = FakeStdio();
    final backend = _HeadlessImageBackend(io, ImageColorMode.indexed256);
    final raster = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 2, rows: 1, cells: ImageCellSize.halfBlock);
    backend.updateImages(#owner, [
      ImagePlacement(
          image: raster,
          row: 0,
          column: 0,
          sourceRow: 0,
          rows: raster.rows,
          columns: raster.columns)
    ]);
    backend.flush();
    final out = io.written.toString();
    expect(out, contains('38;5;'));
    expect(out, isNot(contains('38;2;')));
  });

  test('ImagePanelContent writes caption and image rows, refits on resize',
      () {
    final io = FakeStdio();
    final backend = _HeadlessImageBackend(io, ImageColorMode.truecolor);
    final screen = Screen.withBackend(
        io: io,
        backend: backend,
        layout: ScreenLayout.fromSize(30, 12, split: false));
    addTearDown(screen.dispose);
    final content = ImagePanelContent(screen, label: 'demo');
    content.image = ConsoleImage.decode(base64Decode(redPng));
    content.fit(const Rect(row: 1, col: 1, width: 20, height: 8),
        reserveInputRow: false);
    content.attach();
    screen.frame(() {
      content.repaint();
    });
    backend.flush();
    final out = io.written.toString();
    expect(out, contains('demo'));
    expect(out, contains('▀'));

    // Resize: a new interior re-fits; the raster cache makes it cheap and
    // the second fit repaints with a different geometry.
    io.written.clear();
    content.fit(const Rect(row: 1, col: 1, width: 10, height: 6),
        reserveInputRow: false);
    content.repaint();
    expect(io.written.toString(), contains('demo'));

    // No image: the status row, never a crash.
    final empty = ImagePanelContent(screen, label: 'empty');
    empty.fit(const Rect(row: 1, col: 1, width: 20, height: 8),
        reserveInputRow: false);
    empty.attach();
    backend.flush();
    expect(io.written.toString(), contains('(no image)'));
  });

  test('ImagePanelSpec carries content references renderer-agnostically', () {
    final spec = ImagePanelSpec(
        path: '/tmp/a.png', bytes: Uint8List(0), label: 'both');
    expect(spec.path, '/tmp/a.png');
    expect(spec.label, 'both');
    expect(
        () => ImagePanelSpec(label: 'none'),
        throwsA(isA<AssertionError>()));
  });
}
