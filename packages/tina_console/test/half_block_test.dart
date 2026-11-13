import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

/// Builds a raster whose u32 words use the buffer's real packing:
/// RGBA bytes, so on a little-endian host a word is A<<24|B<<16|G<<8|R.
ImageRaster _raster(List<int> pixels, int width, int height,
        {ImageCellSize? cells}) =>
    ImageRaster(
        rgba: Uint32List.fromList(pixels),
        width: width,
        height: height,
        cells: cells ?? ImageCellSize.halfBlock);

// Opaque channel packers in the A<<24|B<<16|G<<8|R layout.
int _rgb(int r, int g, int b) =>
    0xFF000000 | (b << 16) | (g << 8) | r;
int _rgba(int r, int g, int b, int a) => (a << 24) | (b << 16) | (g << 8) | r;

void main() {
  test('truecolor one cell: top pixel fg, bottom pixel bg, reset at end',
      () {
    final raster = _raster([_rgb(255, 0, 0), _rgb(0, 0, 255)], 1, 2);
    final rows = renderHalfBlockRows(raster, truecolor: true);
    expect(rows, hasLength(1));
    expect(rows.single, '\x1b[38;2;255;0;0;48;2;0;0;255m▀\x1b[0m');
  });

  test('truecolor run-length: one SGR covers runs of identical cells', () {
    // Two cells in one row with identical top/bottom pixels. The buffer
    // is row-major: [top0, top1, bottom0, bottom1].
    final pixels = [
      _rgb(0x10, 0x20, 0x30), // top, cell 0
      _rgb(0x10, 0x20, 0x30), // top, cell 1
      _rgb(0x40, 0x50, 0x60), // bottom, cell 0
      _rgb(0x40, 0x50, 0x60), // bottom, cell 1
    ];
    final rows = renderHalfBlockRows(_raster(pixels, 2, 2), truecolor: true);
    expect(rows.single, '\x1b[38;2;16;32;48;48;2;64;80;96m▀▀\x1b[0m');
  });

  test('xterm-256: exact palette anchors quantize without error', () {
    expect(nearestXterm256(0, 0, 0), 16);
    expect(nearestXterm256(255, 255, 255), 231);
    expect(nearestXterm256(8, 8, 8), 232);
    expect(nearestXterm256(238, 238, 238), 255);
    expect(xterm256Rgb(16), (0, 0, 0));
    expect(xterm256Rgb(231), (255, 255, 255));
    expect(xterm256Rgb(232), (8, 8, 8));
  });

  test('xterm-256 cells emit palette indices', () {
    final pixels = [
      _rgb(255, 0, 0), // top, cell 0
      _rgb(255, 0, 0), // top, cell 1
      _rgb(0, 0, 255), // bottom, cell 0
      _rgb(0, 0, 255), // bottom, cell 1
    ];
    final rows = renderHalfBlockRows(_raster(pixels, 2, 2), truecolor: false);
    expect(rows.single, startsWith('\x1b[38;5;'));
    expect(rows.single, contains(';48;5;'));
    expect(rows.single, endsWith('▀▀\x1b[0m'));
    expect(rows.single, isNot(contains('38;2')));
  });

  test('Floyd-Steinberg carries error into the next pixel', () {
    // A row of pixels exactly between two cube levels: with diffusion,
    // later cells must not all quantize identically.
    final width = 8;
    final mid = _rgb(43, 43, 43); // 43 sits between ramp 38 and 48
    final rows =
        renderHalfBlockRows(_raster(List.filled(width * 2, mid), width, 2),
            truecolor: false);
    final indices =
        RegExp(r'38;5;(\d+)').allMatches(rows.first).map((m) => m[1]);
    expect(indices.toSet().length, greaterThan(1),
        reason: 'diffusion must split the mid-level run: $rows');
  });

  test('alpha composites over the background', () {
    // Half-alpha pure blue over opaque red background: channels blend.
    final raster = _raster(
        [_rgba(0, 0, 255, 0x80), _rgba(0, 0, 255, 0x80)], 1, 2);
    final rows = renderHalfBlockRows(raster,
        truecolor: true, background: _rgb(255, 0, 0));
    // r = (0*128 + 255*127 + 127)/255 = 127, b = (255*128 + 127)/255 = 128.
    expect(rows.single, contains('38;2;127;0;128'));
  });

  test('non-(1,2) rasters are rejected', () {
    final raster = _raster([1, 2], 1, 2, cells: const ImageCellSize(1, 1));
    expect(() => renderHalfBlockRows(raster, truecolor: true),
        throwsA(isA<ArgumentError>()));
  });
}
