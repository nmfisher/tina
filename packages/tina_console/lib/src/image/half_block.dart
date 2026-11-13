/// Half-block cell renderer for terminals with no pixel-graphics protocol.
///
/// Each terminal cell shows U+2580 (`▀`, upper half block) with the TOP
/// image pixel as the cell foreground and the BOTTOM pixel as the cell
/// background, so one cell carries two vertical pixels (cell aspect ~2:1;
/// the raster is fitted with [ImageCellSize.halfBlock] upstream by
/// [ConsoleImage.fit]).
///
/// Two color modes:
/// - truecolor: `38;2;r;g;b` / `48;2;r;g;b` SGR per cell.
/// - xterm-256: nearest of the 6x6x6 cube + 24-step gray ramp, with
///   Floyd-Steinberg error diffusion over the pixel grid so gradients
///   survive the coarse palette.
///
/// Pure functions over [ImageRaster] - no I/O, no terminal, fully
/// golden-testable. The ANSI backend owns emission (ansi_backend.dart).
library;

import 'dart:typed_data';

import '../console_image.dart';

/// Renders [raster] into one styled string per terminal row.
///
/// [truecolor] selects direct-color SGR; otherwise colors are quantized
/// to the xterm-256 palette with Floyd-Steinberg dithering. Pixels with
/// alpha are composited over [background] (opaque black by default).
///
/// Channel order: [ImageRaster.rgba] is RGBA *bytes* (produced by
/// `getBytes(order: rgba)`), so a u32 word on a little-endian host packs
/// as A<<24 | B<<16 | G<<8 | R — the helpers below are the one place
/// that unpacking happens.
List<String> renderHalfBlockRows(ImageRaster raster,
    {required bool truecolor, int background = 0xFF000000}) {
  final cells = raster.cells;
  if (cells.width != 1 || cells.height != 2) {
    throw ArgumentError.value(cells, 'cells',
        'half-block rendering needs a (1, 2) pixel-per-cell raster');
  }
  final pixels = truecolor
      ? _compositeAll(raster, background)
      : _quantizeWithFloydSteinberg(raster, background);
  final rows = <String>[];
  final buffer = StringBuffer();
  for (var cellRow = 0; cellRow < raster.rows; cellRow++) {
    buffer.clear();
    var previousFg = -1, previousBg = -1;
    for (var cellCol = 0; cellCol < raster.columns; cellCol++) {
      final top = pixels[cellRow * 2 * raster.width + cellCol];
      final bottom = pixels[(cellRow * 2 + 1) * raster.width + cellCol];
      final sgr = StringBuffer();
      if (top != previousFg) {
        sgr.write(truecolor
            ? '38;2;${top & 0xFF};${(top >> 8) & 0xFF};${(top >> 16) & 0xFF}'
            : '38;5;$top');
        previousFg = top;
      }
      if (bottom != previousBg) {
        if (sgr.isNotEmpty) sgr.write(';');
        sgr.write(truecolor
            ? '48;2;${bottom & 0xFF};${(bottom >> 8) & 0xFF};${(bottom >> 16) & 0xFF}'
            : '48;5;$bottom');
      }
      previousBg = bottom;
      if (sgr.isNotEmpty) buffer.write('\x1b[${sgr}m');
      buffer.write('▀');
    }
    if (buffer.isNotEmpty) buffer.write('\x1b[0m');
    rows.add(buffer.toString());
  }
  return rows;
}

/// Composites every pixel over [background] and returns packed
/// A<<24|B<<16|G<<8|R words (the raster's own packing).
Uint32List _compositeAll(ImageRaster raster, int background) {
  final out = Uint32List(raster.width * raster.height);
  for (var i = 0; i < out.length; i++) {
    out[i] = _composite(raster.rgba[i], background);
  }
  return out;
}

int _composite(int pixel, int background) {
  final alpha = (pixel >> 24) & 0xFF;
  if (alpha == 0xFF) return pixel;
  if (alpha == 0) return background;
  int blend(int channel, int bgChannel) =>
      (channel * alpha + bgChannel * (0xFF - alpha) + 127) ~/ 0xFF;
  return (alpha << 24) |
      (blend((pixel >> 16) & 0xFF, (background >> 16) & 0xFF) << 16) |
      (blend((pixel >> 8) & 0xFF, (background >> 8) & 0xFF) << 8) |
      blend(pixel & 0xFF, background & 0xFF);
}

/// Classic Floyd-Steinberg over the full pixel grid: each pixel is
/// adjusted by accumulated quantization error, quantized to the nearest
/// xterm-256 color, and its error distributed right (7/16), down-left
/// (3/16), down (5/16) and down-right (1/16). Returns per-pixel palette
/// indices (the 16 theme-mapped base colors are skipped).
Uint8List _quantizeWithFloydSteinberg(ImageRaster raster, int background) {
  final width = raster.width;
  final height = raster.height;
  final out = Uint8List(width * height);
  final errors = Float32List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      final argb = _composite(raster.rgba[index], background);
      final base = index * 3;
      // Same A<<24|B<<16|G<<8|R packing as everywhere in this library.
      final r = (argb & 0xFF) + errors[base];
      final g = ((argb >> 8) & 0xFF) + errors[base + 1];
      final b = ((argb >> 16) & 0xFF) + errors[base + 2];
      final palette = nearestXterm256(r.round().clamp(0, 255),
          g.round().clamp(0, 255), b.round().clamp(0, 255));
      out[index] = palette;
      final (pr, pg, pb) = xterm256Rgb(palette);
      final dr = r - pr, dg = g - pg, db = b - pb;
      void push(int nx, int ny, double weight) {
        if (nx < 0 || nx >= width || ny >= height) return;
        final target = (ny * width + nx) * 3;
        errors[target] += dr * weight;
        errors[target + 1] += dg * weight;
        errors[target + 2] += db * weight;
      }

      push(x + 1, y, 7 / 16);
      push(x - 1, y + 1, 3 / 16);
      push(x, y + 1, 5 / 16);
      push(x + 1, y + 1, 1 / 16);
    }
  }
  return out;
}

const _cubeLevels = [0, 95, 135, 175, 215, 255];

/// The RGB value of an xterm-256 palette index (cube 16..231, gray
/// 232..255; the theme-mapped base 16 are never chosen).
(int, int, int) xterm256Rgb(int index) {
  if (index >= 232) {
    final level = 8 + (index - 232) * 10;
    return (level, level, level);
  }
  final cube = index - 16;
  return (
    _cubeLevels[(cube ~/ 36) % 6],
    _cubeLevels[(cube ~/ 6) % 6],
    _cubeLevels[cube % 6],
  );
}

/// Nearest xterm-256 index for a color: the 6x6x6 cube (16..231) and the
/// 24-step gray ramp (232..255), minimizing squared distance. The search
/// is exact over the 240 fixed candidates.
int nearestXterm256(int r, int g, int b) {
  var best = 16;
  var bestDistance = _distance2(
      r, g, b, _cubeLevels[0], _cubeLevels[0], _cubeLevels[0]);
  for (var ri = 0; ri < 6; ri++) {
    for (var gi = 0; gi < 6; gi++) {
      for (var bi = 0; bi < 6; bi++) {
        final index = 16 + ri * 36 + gi * 6 + bi;
        final distance =
            _distance2(r, g, b, _cubeLevels[ri], _cubeLevels[gi], _cubeLevels[bi]);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = index;
        }
      }
    }
  }
  for (var step = 0; step < 24; step++) {
    final level = 8 + step * 10;
    final distance = _distance2(r, g, b, level, level, level);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = 232 + step;
    }
  }
  return best;
}

int _distance2(int r1, int g1, int b1, int r2, int g2, int b2) {
  final dr = r1 - r2, dg = g1 - g2, db = b1 - b2;
  return dr * dr + dg * dg + db * db;
}
