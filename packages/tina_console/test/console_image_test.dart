import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:image/image.dart' as img;
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'notcurses_backend_platform_test.dart' show RecordingPlatform;
import 'stdio_fake.dart';

const redPng =
    'iVBORw0KGgoAAAANSUhEUgAAABgAAAAgCAYAAAAIXrg4AAAAJ0lEQVR4nO3NsQ0AAAjAoP7/tF7hYMLATFNzKYFAIBAIBAKBQPAlWMuz+kyFM+vqAAAAAElFTkSuQmCC';

class ImageBackend extends AnsiBackend implements RetainedImageBackend {
  ImageBackend(FakeStdio io) : super(io: io, ansi: AnsiCapable.yes);
  @override
  ImageCellSize imageCellSize = ImageCellSize.halfBlock;
  final images = <Object, List<ImagePlacement>>{};
  @override
  bool updateImages(Object owner, List<ImagePlacement> placements,
      {BackendSurface? targetSurface}) {
    images[owner] = List.of(placements);
    return true;
  }

  @override
  void clearImages(Object owner) => images.remove(owner);
}

class ImagePlane implements NotcursesImagePlane {
  int raises = 0, destroys = 0;
  bool throwOnDestroy = false;
  @override
  void raise() => raises++;
  @override
  void destroy() {
    destroys++;
    if (throwOnDestroy) throw StateError('image cleanup failed');
  }
}

void main() {
  test('crops source rows and packs columns without reading adjacent pixels',
      () {
    // A subview with distinct values makes offsets, strides and accidental
    // scaling of the full source visible in the expected pixel rectangle.
    final storage = Uint32List.fromList([999, ...List.generate(20, (i) => i)]);
    final image = ImageRaster(
        rgba: Uint32List.sublistView(storage, 1),
        width: 5,
        height: 4,
        cells: ImageCellSize.halfBlock);
    final fullWidth = image.cropRgba(top: 2, width: 5, height: 2);
    expect(Uint32List.sublistView(fullWidth),
        [10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);
    final narrow = image.cropRgba(top: 1, width: 3, height: 2);
    expect(Uint32List.sublistView(narrow), [5, 6, 7, 10, 11, 12]);
    expect(Uint32List.sublistView(image.cropRgba(top: 3, width: 1, height: 1)),
        [15]);
    for (final crop in [
      (top: -1, width: 5, height: 1),
      (top: 3, width: 5, height: 2),
      (top: 0, width: 6, height: 1),
      (top: 0, width: 1, height: 0)
    ]) {
      expect(
          () => image.cropRgba(
              top: crop.top, width: crop.width, height: crop.height),
          throwsArgumentError);
    }
  });
  test('16-bit and RGB images become 8-bit RGBA while preserving alpha', () {
    final highDepth = img.Image(
        width: 2, height: 2, format: img.Format.uint16, numChannels: 4)
      ..setPixelRgba(0, 0, 65535, 32768, 0, 32768);
    final decoded = ConsoleImage.decode(img.encodePng(highDepth))!;
    final raster =
        decoded.fit(columns: 2, rows: 1, cells: ImageCellSize.halfBlock);
    final bytes = raster.rgba.buffer.asUint8List();
    expect(bytes.length, 16);
    expect(bytes[0], 255);
    expect(bytes[1], inInclusiveRange(127, 128));
    expect(bytes[2], 0);
    expect(bytes[3], inInclusiveRange(127, 128));
    final rgb = img.Image(width: 2, height: 2, numChannels: 3)
      ..setPixelRgb(0, 0, 255, 0, 0);
    final opaque = ConsoleImage.decode(img.encodePng(rgb))!
        .fit(columns: 2, rows: 1, cells: ImageCellSize.halfBlock);
    expect(opaque.rgba.buffer.asUint8List().take(4), [255, 0, 0, 255]);
  });
  test('decodes, preserves aspect and RGBA, fits/caches both blitters', () {
    final image = ConsoleImage.decode(base64Decode(redPng))!;
    expect((image.width, image.height), (24, 32));
    final blocks =
        image.fit(columns: 12, rows: 4, cells: ImageCellSize.halfBlock);
    expect((blocks.width, blocks.height, blocks.columns, blocks.rows),
        (6, 8, 6, 4));
    expect(blocks.rgba.buffer.asUint8List().take(4), [255, 0, 0, 255]);
    expect(image.fit(columns: 12, rows: 4, cells: ImageCellSize.halfBlock),
        same(blocks));
    final pixels =
        image.fit(columns: 3, rows: 1, cells: const ImageCellSize(8, 16));
    expect((pixels.width, pixels.height, pixels.columns, pixels.rows),
        (12, 16, 2, 1));
    expect(ConsoleImage.decode(Uint8List.fromList([1, 2, 3])), isNull);
    expect(
        () => ImageRaster(
            rgba: Uint32List(1),
            width: 2,
            height: 2,
            cells: ImageCellSize.halfBlock),
        throwsArgumentError);
  });

  test('retained images crop and follow scrollback, resize, detach and clear',
      () {
    final io = FakeStdio();
    final backend = ImageBackend(io);
    final screen = Screen.withBackend(
        io: io,
        backend: backend,
        layout: ScreenLayout.fromSize(30, 10, split: false));
    addTearDown(screen.dispose);
    final chat = screen.chat;
    final image = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 20, rows: 8, cells: backend.imageCellSize);
    final imageLines = [
      for (var i = 0; i < image.rows; i++)
        RegionLine(' ', image: ImageRow(image, i, column: 3))
    ];
    chat.rewriteFrom(0, [
      const RegionLine('caption'),
      ...imageLines,
      for (var i = 0; i < 4; i++) RegionLine('after $i')
    ]);
    final tail = backend.images[chat]!.single;
    expect(tail.sourceRow, greaterThan(0));
    expect(tail.row, chat.bounds.row);
    expect(tail.row + tail.rows, lessThanOrEqualTo(chat.bounds.bottom));
    expect(tail.column, chat.bounds.col + 3);
    chat.scrollBy(-2);
    final previous = backend.images[chat]!.single;
    expect(previous.sourceRow, tail.sourceRow - 2);
    chat.scrollToTail();
    expect(backend.images[chat]!.single, tail);
    screen.resize(ScreenLayout.fromSize(12, 8, split: false));
    chat.scrollBy(-2);
    final narrow = backend.images[chat]!.single;
    expect(narrow.columns, lessThanOrEqualTo(chat.bounds.width - 3));
    expect(narrow.row + narrow.rows, lessThanOrEqualTo(chat.bounds.bottom));
    chat.detach();
    expect(backend.images, isEmpty);
    chat.attach();
    expect(backend.images[chat], isNotEmpty);
    chat.resetAfterClear();
    chat.repaint();
    expect(backend.images, isEmpty);
  });

  test('append rows survive history eviction and independent panels', () {
    final io = FakeStdio();
    final backend = ImageBackend(io);
    final screen = Screen.withBackend(
        io: io,
        backend: backend,
        layout: ScreenLayout.fromSize(30, 10, split: false));
    addTearDown(screen.dispose);
    final image = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 10, rows: 3, cells: backend.imageCellSize);
    final chat = screen.chat;
    chat.rewriteFrom(0, List.generate(2100, (i) => RegionLine('old $i')));
    for (var row = 0; row < image.rows; row++) {
      chat.writeLine(RegionLine(' ', image: ImageRow(image, row)));
    }
    expect(backend.images[chat]!.single.sourceRow, 0);
    final other = ScrollingTextRegion(screen,
        bounds: const Rect(row: 0, col: 15, width: 15, height: 8));
    other.writeLine(RegionLine(' ', image: ImageRow(image, 0)));
    expect(backend.images.length, 2);
    other.detach();
    expect(backend.images[chat], isNotEmpty);
    chat.rewriteFrom(0, [const RegionLine('replacement')]);
    expect(backend.images, isEmpty);
  });

  test('native backend reuses stable planes and destroys on crop/clear/stop',
      () {
    final io = FakeStdio();
    final platform = RecordingPlatform();
    final planes = <ImagePlane>[];
    final seen = <ImagePlacement>[];
    final backend = NotcursesBackend.forTesting(
        io: io,
        platform: platform,
        imagePainter: (placement, surface) {
          seen.add(placement);
          final plane = ImagePlane();
          planes.add(plane);
          return plane;
        });
    backend.enterAltScreen();
    final image = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 10, rows: 4, cells: backend.imageCellSize);
    final owner = Object(), other = Object();
    final placement = ImagePlacement(
        image: image, row: 2, column: 3, sourceRow: 0, rows: 4, columns: 6);
    backend.updateImages(owner, [placement]);
    final presents = backend.presentationCount;
    expect(backend.updateImages(owner, [placement]), isFalse);
    expect(planes, hasLength(1));
    expect(backend.presentationCount, presents,
        reason: 'Idle input refreshes must not recreate or repaint images');
    backend.updateImages(other, [placement]);
    backend.updateImages(owner, [
      ImagePlacement(
          image: image, row: 0, column: 3, sourceRow: 2, rows: 2, columns: 6)
    ]);
    expect(planes.first.destroys, 1);
    expect(planes[1].destroys, 0);
    expect(seen.last.sourceRow, 2);
    backend.clearImages(owner);
    expect(planes.last.destroys, 1);
    backend.leaveAltScreen();
    expect(planes.every((p) => p.destroys == 1), isTrue);
    backend.clearImages(other);
    backend.updateImages(owner, [placement]);
    expect(planes, hasLength(3));
  });

  test('failed image cleanup still restores mouse reporting and stops', () {
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final platform = RecordingPlatform();
    final imagePlane = ImagePlane()..throwOnDestroy = true;
    final backend = NotcursesBackend.forTesting(
        io: io,
        platform: platform,
        imagePainter: (placement, surface) => imagePlane);
    backend.enterAltScreen();
    final image = ConsoleImage.decode(base64Decode(redPng))!
        .fit(columns: 10, rows: 4, cells: backend.imageCellSize);
    backend.updateImages(Object(), [
      ImagePlacement(
          image: image, row: 2, column: 3, sourceRow: 0, rows: 4, columns: 6)
    ]);
    expect(backend.leaveAltScreen, returnsNormally);
    expect(imagePlane.destroys, 1);
    expect(platform.stopped, isTrue);
    for (final mode in [1000, 1002, 1003, 1006, 1016]) {
      expect(platform.rawTtyWrites.join(), contains('\x1b[?${mode}l'));
    }
    platform.calls.clear();
    backend.writeText('late');
    backend.flush();
    expect(platform.calls, isEmpty);
  });
}
