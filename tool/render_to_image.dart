/// Visual TUI renderer — captures ANSI output and writes a PPM image.
///
/// Usage: dart run tool/render_to_image.dart
/// Produces: /tmp/tui_snapshot.ppm (and .png if ImageMagick convert is available)
library;

import 'dart:io';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/line_layout.dart';
import 'package:tina_console/src/panel_layout.dart';
import 'package:tina_console/src/panel_renderer.dart';

// ---------------------------------------------------------------------------
// VirtualTerminal with per-cell attribute tracking
// ---------------------------------------------------------------------------

/// RGB color.
class Rgb {
  final int r, g, b;
  const Rgb(this.r, this.g, this.b);
  static const black = Rgb(0, 0, 0);
  static const white = Rgb(255, 255, 255);
  static const gray = Rgb(128, 128, 128);
  static const darkGray = Rgb(80, 80, 80);
  static const cyan = Rgb(0, 200, 220);
  static const green = Rgb(0, 200, 80);
  static const yellow = Rgb(220, 200, 0);
  static const red = Rgb(200, 50, 50);
  static const darkCyan = Rgb(0, 130, 150);
}

/// Per-cell attributes.
class CellAttr {
  final Rgb fg;
  final Rgb bg;
  final bool reverse;
  final bool dim;
  final bool bold;

  const CellAttr({
    this.fg = Rgb.white,
    this.bg = Rgb.black,
    this.reverse = false,
    this.dim = false,
    this.bold = false,
  });

  Rgb get effectiveFg => reverse ? bg : fg;
  Rgb get effectiveBg => reverse ? fg : bg;
}

/// A terminal screen cell.
class Cell {
  String char;
  CellAttr attr;
  Cell({this.char = ' ', this.attr = const CellAttr()});
}

/// ANSI terminal emulator with attribute tracking.
class AttrVT {
  final int width;
  final int height;
  late final List<List<Cell>> grid;
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _pendingWrap = false;

  // Current attributes
  Rgb _fg = Rgb.white;
  Rgb _bg = Rgb.black;
  bool _reverse = false;
  bool _dim = false;
  bool _bold = false;

  // Saved cursor
  int _savedRow = 0;
  int _savedCol = 0;

  AttrVT({required this.width, required this.height}) {
    grid = List.generate(height, (_) => List.generate(width, (_) => Cell()));
  }

  void feed(String s) {
    var i = 0;
    final runes = s.runes.toList();
    while (i < runes.length) {
      final ch = runes[i];
      if (ch == 0x1b) {
        i = _handleEscape(s, runes, i);
      } else if (ch == 0x0d) {
        _cursorCol = 0;
        _pendingWrap = false;
        i++;
      } else if (ch == 0x0a) {
        _cursorRow++;
        _pendingWrap = false;
        if (_cursorRow >= height) _cursorRow = height - 1;
        i++;
      } else if (ch >= 0x20) {
        _putChar(String.fromCharCode(ch));
        i++;
      } else {
        i++; // skip other control chars
      }
    }
  }

  void _putChar(String ch) {
    if (_pendingWrap) {
      _cursorCol = 0;
      _cursorRow++;
      _pendingWrap = false;
      if (_cursorRow >= height) _cursorRow = height - 1;
    }
    if (_cursorRow >= 0 &&
        _cursorRow < height &&
        _cursorCol >= 0 &&
        _cursorCol < width) {
      grid[_cursorRow][_cursorCol] = Cell(
        char: ch,
        attr: CellAttr(
          fg: _fg,
          bg: _bg,
          reverse: _reverse,
          dim: _dim,
          bold: _bold,
        ),
      );
      _cursorCol++;
      if (_cursorCol >= width) {
        _pendingWrap = true;
        _cursorCol = width - 1;
      }
    }
  }

  int _handleEscape(String s, List<int> runes, int start) {
    if (start + 1 >= runes.length) return start + 1;
    final next = runes[start + 1];
    if (next == 0x37) {
      // save cursor
      _savedRow = _cursorRow;
      _savedCol = _cursorCol;
      return start + 2;
    }
    if (next == 0x38) {
      // restore cursor
      _cursorRow = _savedRow;
      _cursorCol = _savedCol;
      _pendingWrap = false;
      return start + 2;
    }
    if (next == 0x5b) return _handleCsi(s, runes, start);
    if (next == 0x4f) return start + 3; // SS3
    return start + 2;
  }

  int _handleCsi(String s, List<int> runes, int start) {
    var j = start + 2;
    if (j < runes.length && runes[j] == 0x3f) j++; // ? prefix
    final buf = StringBuffer();
    while (j < runes.length) {
      final ch = runes[j];
      if ((ch >= 0x30 && ch <= 0x3f) || ch == 0x3b) {
        buf.write(String.fromCharCode(ch));
        j++;
      } else {
        break;
      }
    }
    if (j >= runes.length) return j;
    final params = buf.toString();
    final cmd = runes[j];
    j++;

    switch (cmd) {
      case 0x47: // G - cursor horizontal absolute
        _cursorCol = int.parse(params.isEmpty ? '1' : params) - 1;
        _pendingWrap = false;
      case 0x48: // H - cursor position
        _pendingWrap = false;
        final parts = params.isEmpty ? '1;1' : params;
        final semi = parts.indexOf(';');
        if (semi >= 0) {
          _cursorRow = int.parse(parts.substring(0, semi)) - 1;
          _cursorCol = int.parse(parts.substring(semi + 1)) - 1;
        } else {
          _cursorRow = int.parse(parts) - 1;
          _cursorCol = 0;
        }
      case 0x4a: // J - erase in display
        final n = params.isEmpty ? '0' : params;
        if (n == '2') _clearScreen();
      case 0x4b: // K - erase in line
        final n = params.isEmpty ? '0' : params;
        if (n == '0') {
          for (var c = _cursorCol; c < width; c++) {
            grid[_cursorRow][c] = Cell();
          }
        } else if (n == '1') {
          for (var c = 0; c <= _cursorCol && c < width; c++) {
            grid[_cursorRow][c] = Cell();
          }
        }
      case 0x58: // X - erase characters
        final n = params.isEmpty ? 1 : int.parse(params);
        for (var k = 0; k < n && _cursorCol + k < width; k++) {
          grid[_cursorRow][_cursorCol + k] = Cell();
        }
      case 0x41: // A - cursor up
        _cursorRow -= params.isEmpty ? 1 : int.parse(params);
        if (_cursorRow < 0) _cursorRow = 0;
      case 0x42: // B - cursor down
        _cursorRow += params.isEmpty ? 1 : int.parse(params);
        if (_cursorRow >= height) _cursorRow = height - 1;
      case 0x43: // C - cursor forward
        _cursorCol += params.isEmpty ? 1 : int.parse(params);
        if (_cursorCol >= width) _cursorCol = width - 1;
      case 0x44: // D - cursor back
        _cursorCol -= params.isEmpty ? 1 : int.parse(params);
        if (_cursorCol < 0) _cursorCol = 0;
      case 0x6d: // m - SGR (set graphic rendition)
        _applySgr(params);
      case 0x68: // h - set mode
      case 0x6c: // l - reset mode
        break;
    }
    return j;
  }

  void _applySgr(String params) {
    if (params.isEmpty) {
      _resetAttrs();
      return;
    }
    final codes = params.split(';').map((s) => s.isEmpty ? 0 : int.parse(s));
    for (final code in codes) {
      switch (code) {
        case 0:
          _resetAttrs();
        case 1:
          _bold = true;
        case 2:
          _dim = true;
        case 7:
          _reverse = true;
        case 22:
          _bold = false;
          _dim = false;
        case 27:
          _reverse = false;
        case 30:
          _fg = Rgb.black;
        case 31:
          _fg = Rgb.red;
        case 32:
          _fg = Rgb.green;
        case 33:
          _fg = Rgb.yellow;
        case 34:
          _fg = const Rgb(60, 120, 220);
        case 35:
          _fg = const Rgb(180, 60, 180);
        case 36:
          _fg = Rgb.cyan;
        case 37:
          _fg = Rgb.white;
        case 90:
          _fg = Rgb.darkGray;
        case 39:
          _fg = Rgb.white;
        case 40:
          _bg = Rgb.black;
        case 49:
          _bg = Rgb.black;
      }
    }
  }

  void _resetAttrs() {
    _fg = Rgb.white;
    _bg = Rgb.black;
    _reverse = false;
    _dim = false;
    _bold = false;
  }

  void _clearScreen() {
    for (var r = 0; r < height; r++) {
      for (var c = 0; c < width; c++) {
        grid[r][c] = Cell();
      }
    }
    _cursorRow = 0;
    _cursorCol = 0;
  }
}

// ---------------------------------------------------------------------------
// Bitmap rendering
// ---------------------------------------------------------------------------

/// Simple framebuffer for writing pixel data.
class Framebuffer {
  final int w, h;
  late final List<int> _data; // RGBA

  Framebuffer(this.w, this.h) {
    _data = List.filled(w * h * 4, 0);
    // Fill with black.
    for (var i = 0; i < w * h; i++) {
      _data[i * 4 + 3] = 255; // alpha
    }
  }

  void setPixel(int x, int y, Rgb c) {
    if (x < 0 || x >= w || y < 0 || y >= h) return;
    final off = (y * w + x) * 4;
    _data[off] = c.r;
    _data[off + 1] = c.g;
    _data[off + 2] = c.b;
    _data[off + 3] = 255;
  }

  void fillRect(int x0, int y0, int w, int h, Rgb c) {
    for (var y = y0; y < y0 + h; y++) {
      for (var x = x0; x < x0 + w; x++) {
        setPixel(x, y, c);
      }
    }
  }

  /// Write as PPM (P6 binary).
  void writePpm(String path) {
    final f = File(path);
    final sb = StringBuffer();
    sb.write('P6\n$w $h\n255\n');
    final header = sb.toString().codeUnits;
    final pixels = List<int>.filled(w * h * 3, 0);
    for (var i = 0; i < w * h; i++) {
      pixels[i * 3] = _data[i * 4];
      pixels[i * 3 + 1] = _data[i * 4 + 1];
      pixels[i * 3 + 2] = _data[i * 4 + 2];
    }
    f.writeAsBytesSync([...header, ...pixels]);
  }
}

// ---------------------------------------------------------------------------
// Built-in 8x8 bitmap font (ASCII + box-drawing)
// ---------------------------------------------------------------------------

/// Each glyph is 8 rows of 8 bits (MSB = leftmost pixel).
/// Only the printable ASCII range + box-drawing chars used by the TUI.
const Map<int, List<int>> _font = {
  // space
  0x20: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  // !
  0x21: [0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00],
  // "
  0x22: [0x6c, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  // #
  0x23: [0x6c, 0x6c, 0xfe, 0x6c, 0xfe, 0x6c, 0x6c, 0x00],
  // $
  0x24: [0x18, 0x3e, 0x60, 0x3c, 0x06, 0x7c, 0x18, 0x00],
  // %
  0x25: [0x00, 0x66, 0x6c, 0x18, 0x30, 0x66, 0x46, 0x00],
  // &
  0x26: [0x38, 0x6c, 0x38, 0x76, 0xdc, 0xcc, 0x76, 0x00],
  // '
  0x27: [0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00],
  // (
  0x28: [0x0c, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0c, 0x00],
  // )
  0x29: [0x30, 0x18, 0x0c, 0x0c, 0x0c, 0x18, 0x30, 0x00],
  // *
  0x2a: [0x00, 0x66, 0x3c, 0xff, 0x3c, 0x66, 0x00, 0x00],
  // +
  0x2b: [0x00, 0x18, 0x18, 0x7e, 0x18, 0x18, 0x00, 0x00],
  // ,
  0x2c: [0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30],
  // -
  0x2d: [0x00, 0x00, 0x00, 0x7e, 0x00, 0x00, 0x00, 0x00],
  // .
  0x2e: [0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00],
  // /
  0x2f: [0x02, 0x06, 0x0c, 0x18, 0x30, 0x60, 0x40, 0x00],
  // 0-9
  0x30: [0x3c, 0x66, 0x6e, 0x7e, 0x76, 0x66, 0x3c, 0x00],
  0x31: [0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7e, 0x00],
  0x32: [0x3c, 0x66, 0x06, 0x0c, 0x18, 0x30, 0x7e, 0x00],
  0x33: [0x3c, 0x66, 0x06, 0x1c, 0x06, 0x66, 0x3c, 0x00],
  0x34: [0x0c, 0x1c, 0x3c, 0x6c, 0x7e, 0x0c, 0x0c, 0x00],
  0x35: [0x7e, 0x60, 0x7c, 0x06, 0x06, 0x66, 0x3c, 0x00],
  0x36: [0x1c, 0x30, 0x60, 0x7c, 0x66, 0x66, 0x3c, 0x00],
  0x37: [0x7e, 0x06, 0x0c, 0x18, 0x30, 0x30, 0x30, 0x00],
  0x38: [0x3c, 0x66, 0x66, 0x3c, 0x66, 0x66, 0x3c, 0x00],
  0x39: [0x3c, 0x66, 0x66, 0x3e, 0x06, 0x0c, 0x38, 0x00],
  // :
  0x3a: [0x00, 0x00, 0x18, 0x00, 0x00, 0x18, 0x00, 0x00],
  // ;
  0x3b: [0x00, 0x00, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30],
  // <
  0x3c: [0x0c, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0c, 0x00],
  // =
  0x3d: [0x00, 0x00, 0x7e, 0x00, 0x7e, 0x00, 0x00, 0x00],
  // >
  0x3e: [0x30, 0x18, 0x0c, 0x06, 0x0c, 0x18, 0x30, 0x00],
  // ?
  0x3f: [0x3c, 0x66, 0x0c, 0x18, 0x18, 0x00, 0x18, 0x00],
  // @
  0x40: [0x3c, 0x66, 0x6e, 0x6e, 0x60, 0x62, 0x3c, 0x00],
  // A-Z
  0x41: [0x18, 0x3c, 0x66, 0x7e, 0x66, 0x66, 0x66, 0x00],
  0x42: [0x7c, 0x66, 0x66, 0x7c, 0x66, 0x66, 0x7c, 0x00],
  0x43: [0x3c, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3c, 0x00],
  0x44: [0x78, 0x6c, 0x66, 0x66, 0x66, 0x6c, 0x78, 0x00],
  0x45: [0x7e, 0x60, 0x60, 0x78, 0x60, 0x60, 0x7e, 0x00],
  0x46: [0x7e, 0x60, 0x60, 0x78, 0x60, 0x60, 0x60, 0x00],
  0x47: [0x3c, 0x66, 0x60, 0x6e, 0x66, 0x66, 0x3e, 0x00],
  0x48: [0x66, 0x66, 0x66, 0x7e, 0x66, 0x66, 0x66, 0x00],
  0x49: [0x3c, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c, 0x00],
  0x4a: [0x1e, 0x0c, 0x0c, 0x0c, 0x0c, 0x6c, 0x38, 0x00],
  0x4b: [0x66, 0x6c, 0x78, 0x70, 0x78, 0x6c, 0x66, 0x00],
  0x4c: [0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7e, 0x00],
  0x4d: [0x63, 0x77, 0x7f, 0x6b, 0x63, 0x63, 0x63, 0x00],
  0x4e: [0x66, 0x76, 0x7e, 0x7e, 0x6e, 0x66, 0x66, 0x00],
  0x4f: [0x3c, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3c, 0x00],
  0x50: [0x7c, 0x66, 0x66, 0x7c, 0x60, 0x60, 0x60, 0x00],
  0x51: [0x3c, 0x66, 0x66, 0x66, 0x66, 0x3c, 0x0e, 0x00],
  0x52: [0x7c, 0x66, 0x66, 0x7c, 0x6c, 0x66, 0x66, 0x00],
  0x53: [0x3c, 0x66, 0x60, 0x3c, 0x06, 0x66, 0x3c, 0x00],
  0x54: [0x7e, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00],
  0x55: [0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3c, 0x00],
  0x56: [0x66, 0x66, 0x66, 0x66, 0x66, 0x3c, 0x18, 0x00],
  0x57: [0x63, 0x63, 0x63, 0x6b, 0x7f, 0x77, 0x63, 0x00],
  0x58: [0x66, 0x66, 0x3c, 0x18, 0x3c, 0x66, 0x66, 0x00],
  0x59: [0x66, 0x66, 0x66, 0x3c, 0x18, 0x18, 0x18, 0x00],
  0x5a: [0x7e, 0x06, 0x0c, 0x18, 0x30, 0x60, 0x7e, 0x00],
  // [
  0x5b: [0x3c, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3c, 0x00],
  // backslash
  0x5c: [0x40, 0x60, 0x30, 0x18, 0x0c, 0x06, 0x02, 0x00],
  // ]
  0x5d: [0x3c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x3c, 0x00],
  // ^
  0x5e: [0x18, 0x3c, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00],
  // _
  0x5f: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0x00],
  // `
  0x60: [0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  // a-z
  0x61: [0x00, 0x00, 0x3c, 0x06, 0x3e, 0x66, 0x3e, 0x00],
  0x62: [0x60, 0x60, 0x7c, 0x66, 0x66, 0x66, 0x7c, 0x00],
  0x63: [0x00, 0x00, 0x3c, 0x66, 0x60, 0x66, 0x3c, 0x00],
  0x64: [0x06, 0x06, 0x3e, 0x66, 0x66, 0x66, 0x3e, 0x00],
  0x65: [0x00, 0x00, 0x3c, 0x66, 0x7e, 0x60, 0x3c, 0x00],
  0x66: [0x1c, 0x36, 0x30, 0x7c, 0x30, 0x30, 0x30, 0x00],
  0x67: [0x00, 0x00, 0x3e, 0x66, 0x66, 0x3e, 0x06, 0x3c],
  0x68: [0x60, 0x60, 0x7c, 0x66, 0x66, 0x66, 0x66, 0x00],
  0x69: [0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3c, 0x00],
  0x6a: [0x0c, 0x00, 0x0c, 0x0c, 0x0c, 0x0c, 0x6c, 0x38],
  0x6b: [0x60, 0x60, 0x66, 0x6c, 0x78, 0x6c, 0x66, 0x00],
  0x6c: [0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c, 0x00],
  0x6d: [0x00, 0x00, 0x66, 0x7f, 0x7f, 0x6b, 0x63, 0x00],
  0x6e: [0x00, 0x00, 0x7c, 0x66, 0x66, 0x66, 0x66, 0x00],
  0x6f: [0x00, 0x00, 0x3c, 0x66, 0x66, 0x66, 0x3c, 0x00],
  0x70: [0x00, 0x00, 0x7c, 0x66, 0x66, 0x7c, 0x60, 0x60],
  0x71: [0x00, 0x00, 0x3e, 0x66, 0x66, 0x3e, 0x06, 0x06],
  0x72: [0x00, 0x00, 0x7c, 0x66, 0x60, 0x60, 0x60, 0x00],
  0x73: [0x00, 0x00, 0x3e, 0x60, 0x3c, 0x06, 0x7c, 0x00],
  0x74: [0x30, 0x30, 0x7c, 0x30, 0x30, 0x36, 0x1c, 0x00],
  0x75: [0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3e, 0x00],
  0x76: [0x00, 0x00, 0x66, 0x66, 0x66, 0x3c, 0x18, 0x00],
  0x77: [0x00, 0x00, 0x63, 0x6b, 0x7f, 0x7f, 0x36, 0x00],
  0x78: [0x00, 0x00, 0x66, 0x3c, 0x18, 0x3c, 0x66, 0x00],
  0x79: [0x00, 0x00, 0x66, 0x66, 0x66, 0x3e, 0x06, 0x3c],
  0x7a: [0x00, 0x00, 0x7e, 0x0c, 0x18, 0x30, 0x7e, 0x00],
  // {
  0x7b: [0x0e, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0e, 0x00],
  // |
  0x7c: [0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00],
  // }
  0x7d: [0x70, 0x18, 0x18, 0x0e, 0x18, 0x18, 0x70, 0x00],
  // ~
  0x7e: [0x00, 0x00, 0x76, 0xdc, 0x00, 0x00, 0x00, 0x00],
};

/// Get the font bitmap for a codepoint. Falls back to a filled block.
List<int> _glyph(int cp) {
  final g = _font[cp];
  if (g != null) return g;
  // Box-drawing and other Unicode — render as block
  if (cp == 0x2500) return [0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00]; // ─
  if (cp == 0x2502) return [0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00]; // │
  if (cp == 0x250c) return [0x00, 0x00, 0x00, 0x1f, 0x18, 0x18, 0x18, 0x18]; // ┌
  if (cp == 0x2510) return [0x00, 0x00, 0x00, 0xf8, 0x18, 0x18, 0x18, 0x18]; // ┐
  if (cp == 0x2514) return [0x18, 0x18, 0x18, 0x1f, 0x00, 0x00, 0x00, 0x00]; // └
  if (cp == 0x2518) return [0x18, 0x18, 0x18, 0xf8, 0x00, 0x00, 0x00, 0x00]; // ┘
  if (cp == 0x251c) return [0x18, 0x18, 0x18, 0x1f, 0x18, 0x18, 0x18, 0x18]; // ├
  if (cp == 0x2524) return [0x18, 0x18, 0x18, 0xf8, 0x18, 0x18, 0x18, 0x18]; // ┤
  if (cp == 0x252c) return [0x00, 0x00, 0x00, 0xff, 0x18, 0x18, 0x18, 0x18]; // ┬
  if (cp == 0x2534) return [0x18, 0x18, 0x18, 0xff, 0x00, 0x00, 0x00, 0x00]; // ┴
  if (cp == 0x253c) return [0x18, 0x18, 0x18, 0xff, 0x18, 0x18, 0x18, 0x18]; // ┼
  // Braille patterns for spinner
  if (cp >= 0x2800 && cp <= 0x28FF) {
    final dots = cp - 0x2800;
    final row = <int>[];
    for (var y = 0; y < 8; y++) {
      int bits = 0;
      // Braille: dots 1,4 at col 0; dots 2,5 at col 1; etc
      // Simplified: just spread dots across the 8x8 grid
      if (y == 1 && (dots & 0x01) != 0) bits |= 0xc0;
      if (y == 1 && (dots & 0x08) != 0) bits |= 0x30;
      if (y == 3 && (dots & 0x02) != 0) bits |= 0xc0;
      if (y == 3 && (dots & 0x10) != 0) bits |= 0x30;
      if (y == 5 && (dots & 0x04) != 0) bits |= 0xc0;
      if (y == 5 && (dots & 0x20) != 0) bits |= 0x30;
      if (y == 7 && (dots & 0x40) != 0) bits |= 0xc0;
      if (y == 7 && (dots & 0x80) != 0) bits |= 0x30;
      row.add(bits);
    }
    return row;
  }
  // fallback: ?
  return _font[0x3f]!;
}

// ---------------------------------------------------------------------------
// Render AttrVT grid to Framebuffer
// ---------------------------------------------------------------------------

const cellW = 8;
const cellH = 8;
const padX = 4;
const padY = 4;

void renderVt(AttrVT vt, String path) {
  final fb = Framebuffer(
    padX * 2 + vt.width * cellW,
    padY * 2 + vt.height * cellH,
  );

  // Background fill (terminal bg color)
  fb.fillRect(0, 0, fb.w, fb.h, const Rgb(30, 30, 30));

  for (var row = 0; row < vt.height; row++) {
    for (var col = 0; col < vt.width; col++) {
      final cell = vt.grid[row][col];
      final attr = cell.attr;
      final fg = attr.effectiveFg;
      final bg = attr.effectiveBg;

      // Dim colors
      final actualFg = attr.dim
          ? Rgb((fg.r * 0.5).round(), (fg.g * 0.5).round(), (fg.b * 0.5).round())
          : fg;

      // Render glyph
      final cp = cell.char.isNotEmpty ? cell.char.codeUnitAt(0) : 0x20;
      // Handle multi-codepoint chars (box-drawing etc)
      int rune;
      if (cell.char.length > 1) {
        rune = cell.char.runes.first;
      } else {
        rune = cp;
      }
      final glyph = _glyph(rune == 0 ? 0x20 : rune);

      final ox = padX + col * cellW;
      final oy = padY + row * cellH;

      for (var py = 0; py < cellH; py++) {
        final bits = py < glyph.length ? glyph[py] : 0;
        for (var px = 0; px < cellW; px++) {
          final on = (bits & (0x80 >> px)) != 0;
          final c = on ? actualFg : bg;
          fb.setPixel(ox + px, oy + py, c);
        }
      }
    }
  }

  fb.writePpm(path);
  print('Wrote $path (${fb.w}x${fb.h})');
}

// ---------------------------------------------------------------------------
// Collector Stdio
// ---------------------------------------------------------------------------

class _CollectorStdio implements Stdio {
  final StringBuffer _buf = StringBuffer();
  String get collected => _buf.toString();
  void clear() => _buf.clear();

  @override
  void write(String s) => _buf.write(s);

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => 100;

  @override
  bool get hasTerminal => true;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------

void main() {
  const termWidth = 100;
  const termHeight = 24;

  final layout = PanelLayout.fromWidth(termWidth);
  final lw = layout.leftWidth;
  final rw = layout.rightWidth;

  // ── Scenario 1: Split panel with borders + greeting + input ──
  final vt1 = AttrVT(width: termWidth, height: termHeight);
  final fakeIo1 = _CollectorStdio();
  final chatRenderer1 = PanelRenderer(
    layout: layout,
    left: true,
    io: fakeIo1,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  // Draw frame
  final frameSb = StringBuffer();
  final leftPad = lw - 8;
  final rightPad = rw - 9;
  frameSb.write('┌── chat ${"─" * leftPad}┬── tools ${"─" * rightPad}┐\r\n');
  final leftSpaces = ' ' * lw;
  final rightSpaces = ' ' * rw;
  for (var row = 1; row < termHeight - 1; row++) {
    frameSb.write('│$leftSpaces│$rightSpaces│\r\n');
  }
  frameSb.write('└${"─" * lw}┴${"─" * rw}┘');
  vt1.feed(frameSb.toString());

  // Position cursor at first content row
  vt1.feed('\x1b[2;3H');

  // Greeting
  fakeIo1.clear();
  chatRenderer1.write(
      '\x1b[36mtina\x1b[0m — /help · /exit · /clear · /compact · /model · /permissions · /sessions · /resume. ESC cancels a turn.\n');
  vt1.feed(fakeIo1.collected);

  fakeIo1.clear();
  chatRenderer1.dim('session: 20260526-abc\n');
  vt1.feed(fakeIo1.collected);

  // Agent response (simulated)
  fakeIo1.clear();
  chatRenderer1.write(
      'I can help you with that. Let me look at the code first.\n');
  vt1.feed(fakeIo1.collected);

  fakeIo1.clear();
  chatRenderer1.color(
      '90', '  → reading lib/repl.dart\n');
  vt1.feed(fakeIo1.collected);

  // Position input at bottom
  vt1.feed('\x1b[${termHeight - 2};1H');
  fakeIo1.clear();
  chatRenderer1.drawSeparator();
  vt1.feed(fakeIo1.collected);
  vt1.feed('\x1b[${termHeight - 1};3H');

  fakeIo1.clear();
  chatRenderer1.write('> ');
  vt1.feed(fakeIo1.collected);

  // Spinner in right panel
  vt1.feed(
      '\x1b7\x1b[1G│\x1b[${layout.dividerCol + 1}G│\x1b[${layout.rightStart + 1}G\x1b[${rw}X\x1b[2m⠋ thinking…\x1b[0m\x1b[${termWidth}G│\x1b8');

  renderVt(vt1, '/tmp/tui_1_normal.ppm');

  // ── Scenario 2: Ctrl+C confirmation dialog ──
  final vt2 = AttrVT(width: termWidth, height: termHeight);
  final fakeIo2 = _CollectorStdio();
  final chatRenderer2 = PanelRenderer(
    layout: layout,
    left: true,
    io: fakeIo2,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  // Draw frame
  vt2.feed(frameSb.toString());
  vt2.feed('\x1b[2;3H');

  // Greeting
  fakeIo2.clear();
  chatRenderer2.write(
      '\x1b[36mtina\x1b[0m — /help · /exit · /clear · /compact · /model\n');
  vt2.feed(fakeIo2.collected);

  // Position input at bottom
  vt2.feed('\x1b[${termHeight - 2};1H');
  fakeIo2.clear();
  chatRenderer2.drawSeparator();
  vt2.feed(fakeIo2.collected);
  vt2.feed('\x1b[${termHeight - 1};3H');

  fakeIo2.clear();
  chatRenderer2.write('> ');
  vt2.feed(fakeIo2.collected);

  // Now simulate the Ctrl+C dialog box using the new absolute positioning.
  // dialogRow = center of content area = (2 + termHeight - 1) ~/ 2 = 12 (1-indexed)
  // In split mode, col = 3
  final cols = lw - 1; // 57
  const dialogMsg = ' Ctrl+C again to exit ';
  final innerW = dialogMsg.length; // 22
  final center2 = ((cols - innerW - 2) ~/ 2).clamp(0, cols); // 16
  final pad2 = ' ' * center2;
  final hLine2 = '─' * innerW;
  final dialogCenterRow = (2 + termHeight - 1) ~/ 2; // row 12 (1-indexed)
  const dialogCol = 3;

  final dialogSb = StringBuffer();
  dialogSb.write('\x1b7');
  // Top border
  dialogSb.write('\x1b[${dialogCenterRow - 1};${dialogCol}H');
  dialogSb.write('$pad2\x1b[7m┌$hLine2┐\x1b[0m\x1b[K');
  // Message row
  dialogSb.write('\x1b[${dialogCenterRow};${dialogCol}H');
  dialogSb.write('$pad2\x1b[7m│$dialogMsg│\x1b[0m\x1b[K');
  // Bottom border
  dialogSb.write('\x1b[${dialogCenterRow + 1};${dialogCol}H');
  dialogSb.write('$pad2\x1b[7m└$hLine2┘\x1b[0m\x1b[K');
  dialogSb.write('\x1b8');

  vt2.feed(dialogSb.toString());

  renderVt(vt2, '/tmp/tui_2_ctrlc_dialog.ppm');

  // ── Scenario 3: Queue display during agent processing ──
  final vt3 = AttrVT(width: termWidth, height: termHeight);
  final fakeIo3 = _CollectorStdio();
  final chatRenderer3 = PanelRenderer(
    layout: layout,
    left: true,
    io: fakeIo3,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  // Draw frame
  vt3.feed(frameSb.toString());
  vt3.feed('\x1b[2;3H');

  // Some chat content
  fakeIo3.clear();
  chatRenderer3.write(
      '\x1b[36mtina\x1b[0m — type your message below.\n');
  vt3.feed(fakeIo3.collected);

  fakeIo3.clear();
  chatRenderer3.write('User: fix the login bug\n');
  vt3.feed(fakeIo3.collected);

  fakeIo3.clear();
  chatRenderer3.color(
      '90', '  → reading lib/auth.dart\n');
  vt3.feed(fakeIo3.collected);

  // Input at bottom
  vt3.feed('\x1b[${termHeight - 2};1H');
  fakeIo3.clear();
  chatRenderer3.drawSeparator();
  vt3.feed(fakeIo3.collected);

  // Queue display: rendered at a fixed position (e.g. row termHeight-1, col 3)
  final qRow = termHeight - 1; // 0-based row 23
  final qCol = 3;
  vt3.feed('\x1b[${termHeight - 1};3H');
  vt3.feed(
      '\x1b7\x1b[${qRow};${qCol}H\x1b[K> this is queued text\x1b8');

  // Also show [2 queued] indicator somewhere
  vt3.feed(
      '\x1b7\x1b[${qRow - 1};${qCol}H\x1b[K\x1b[2m[2 queued]\x1b[0m\x1b8');

  renderVt(vt3, '/tmp/tui_3_queue.ppm');

  // ── Scenario 4: Narrow terminal (no split) with dialog ──
  const narrowW = 80;
  final vt4 = AttrVT(width: narrowW, height: termHeight);
  final fakeIo4 = _CollectorStdio2().._termCols = narrowW;
  final narrowLayout = PanelLayout.fromWidth(narrowW);
  final chatRenderer4 = PanelRenderer(
    layout: narrowLayout,
    left: true,
    io: fakeIo4,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  // Just prompt + dialog (no split frame)
  vt4.feed('\x1b[1;1H');
  fakeIo4.clear();
  chatRenderer4.write(
      '\x1b[36mtina\x1b[0m — /help · /exit · /clear\n');
  vt4.feed(fakeIo4.collected);

  fakeIo4.clear();
  chatRenderer4.write('> ');
  vt4.feed(fakeIo4.collected);

  // Dialog in non-split mode (fallback: relative positioning, room available)
  final narrowCols = narrowW;
  final narrowInnerW = dialogMsg.length;
  final narrowHLine = '─' * narrowInnerW;
  final centerNarrow =
      ((narrowCols - narrowInnerW - 2) ~/ 2).clamp(0, narrowCols);
  final padNarrow = ' ' * centerNarrow;

  final dialogSb4 = StringBuffer();
  dialogSb4.write('\x1b[1B'); // down 1
  dialogSb4.write('\r');
  dialogSb4.write('$padNarrow\x1b[7m┌$narrowHLine┐\x1b[0m\x1b[K');
  dialogSb4.write('\r\n');
  dialogSb4.write('$padNarrow\x1b[7m│$dialogMsg│\x1b[0m\x1b[K');
  dialogSb4.write('\r\n');
  dialogSb4.write('$padNarrow\x1b[7m└$narrowHLine┘\x1b[0m\x1b[K');
  dialogSb4.write('\x1b[3A\r');

  vt4.feed(dialogSb4.toString());
  renderVt(vt4, '/tmp/tui_4_narrow_dialog.ppm');

  // ── Scenario 5: Wide terminal (200 columns) with split panel ──
  const wideW = 200;
  const wideH = 50;
  final wideLayout = PanelLayout.fromWidth(wideW);
  final wideLw = wideLayout.leftWidth;
  final wideRw = wideLayout.rightWidth;

  final vt5 = AttrVT(width: wideW, height: wideH);
  final fakeIo5 = _CollectorStdio2().._termCols = wideW;
  final chatRenderer5 = PanelRenderer(
    layout: wideLayout,
    left: true,
    io: fakeIo5,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  // Draw wide frame
  final wideFrameSb = StringBuffer();
  final wideLeftPad = wideLw - 8;
  final wideRightPad = wideRw - 9;
  wideFrameSb.write('┌── chat ${"─" * wideLeftPad}┬── tools ${"─" * wideRightPad}┐\r\n');
  final wideLeftSpaces = ' ' * wideLw;
  final wideRightSpaces = ' ' * wideRw;
  for (var row = 1; row < wideH - 1; row++) {
    wideFrameSb.write('│$wideLeftSpaces│$wideRightSpaces│\r\n');
  }
  wideFrameSb.write('└${"─" * wideLw}┴${"─" * wideRw}┘');
  vt5.feed(wideFrameSb.toString());
  vt5.feed('\x1b[2;3H');

  // Greeting
  fakeIo5.clear();
  chatRenderer5.write(
      '\x1b[36mtina\x1b[0m — /help · /exit · /clear · /compact · /model · /permissions · /sessions · /resume. ESC cancels a turn.\n');
  vt5.feed(fakeIo5.collected);

  fakeIo5.clear();
  chatRenderer5.dim('session: 20260526-abc\n');
  vt5.feed(fakeIo5.collected);

  // Longer agent response to fill more of the wide panel
  fakeIo5.clear();
  chatRenderer5.write(
      'I\'ll analyze the codebase and find the relevant files for this task. '
      'Let me start by searching for the main entry point and tracing the call graph.\n');
  vt5.feed(fakeIo5.collected);

  fakeIo5.clear();
  chatRenderer5.color('90', '  → reading lib/repl.dart\n');
  vt5.feed(fakeIo5.collected);

  fakeIo5.clear();
  chatRenderer5.color('90', '  → reading lib/agent/agent.dart\n');
  vt5.feed(fakeIo5.collected);

  fakeIo5.clear();
  chatRenderer5.write(
      'The agent loop processes messages in sequence, delegates tool calls through the registry, '
      'and streams partial results back to the renderer. I can see the issue — the message queue '
      'needs to be drained before reading fresh input.\n');
  vt5.feed(fakeIo5.collected);

  // Spinner in right panel
  vt5.feed(
      '\x1b7\x1b[1G│\x1b[${wideLayout.dividerCol + 1}G│\x1b[${wideLayout.rightStart + 1}G\x1b[${wideRw}X\x1b[2m⠋ thinking…\x1b[0m\x1b[${wideW}G│\x1b8');

  // Tool output in right panel
  final statusRenderer5 = PanelRenderer(
    layout: wideLayout,
    left: false,
    io: fakeIo5,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  fakeIo5.clear();
  statusRenderer5.dim('── reading lib/repl.dart ──\n');
  vt5.feed(fakeIo5.collected);

  fakeIo5.clear();
  statusRenderer5.write(
      'class Repl {\n'
      '  final Agent agent;\n'
      '  final LineEditor editor;\n'
      '  final Renderer renderer;\n'
      '  ...\n'
      '  Future<void> run() async {\n');
  vt5.feed(fakeIo5.collected);

  // Input at bottom
  vt5.feed('\x1b[${wideH - 2};1H');
  fakeIo5.clear();
  chatRenderer5.drawSeparator();
  vt5.feed(fakeIo5.collected);
  vt5.feed('\x1b[${wideH - 1};3H');

  fakeIo5.clear();
  chatRenderer5.write('> ');
  vt5.feed(fakeIo5.collected);

  renderVt(vt5, '/tmp/tui_5_wide.ppm');

  // Convert PPM → PNG using Python stdlib (zlib), no external deps needed.
  const pyConvert = r'''
import struct, zlib, sys
def ppm_to_png(ppm, png):
    with open(ppm, 'rb') as f:
        assert f.readline().strip() == b'P6'
        line = f.readline()
        while line.startswith(b'#'): line = f.readline()
        w, h = map(int, line.split())
        assert int(f.readline().strip()) == 255
        px = f.read()
    def chunk(ct, d):
        c = ct + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw.extend(px[y*w*3:(y+1)*w*3])
    idat = chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    iend = chunk(b'IEND', b'')
    with open(png, 'wb') as f: f.write(sig + ihdr + idat + iend)
for n in sys.argv[1:]:
    ppm_to_png(f'/tmp/{n}.ppm', f'/tmp/{n}.png')
    print(f'Converted {n}.ppm -> {n}.png')
''';
  final names = [
    'tui_1_normal',
    'tui_2_ctrlc_dialog',
    'tui_3_queue',
    'tui_4_narrow_dialog',
    'tui_5_wide',
  ];
  try {
    final result = Process.runSync(
        'python3', ['-c', pyConvert, ...names]);
    if (result.exitCode == 0) {
      stdout.write(result.stdout);
    } else {
      stderr.write(result.stderr);
    }
  } catch (e) {
    print('python3 not available, keeping PPM files in /tmp/');
  }

  // Also print text snapshot for quick reference
  print('\n=== Scenario 1: Normal split panel ===');
  _printGrid(vt1);
  print('\n=== Scenario 2: Ctrl+C dialog ===');
  _printGrid(vt2);
  print('\n=== Scenario 3: Queue display ===');
  _printGrid(vt3);
  print('\n=== Scenario 4: Narrow terminal ===');
  _printGrid(vt4);
  print('\n=== Scenario 5: Wide terminal (200x50) ===');
  _printGrid(vt5);
}

void _printGrid(AttrVT vt) {
  for (var r = 0; r < vt.height; r++) {
    final line = StringBuffer();
    for (var c = 0; c < vt.width; c++) {
      final cell = vt.grid[r][c];
      if (cell.attr.reverse) {
        line.write('\x1b[7m${cell.char}\x1b[0m');
      } else if (cell.attr.dim) {
        line.write('\x1b[2m${cell.char}\x1b[0m');
      } else if (cell.attr.fg != Rgb.white) {
        line.write(cell.char);
      } else {
        line.write(cell.char);
      }
    }
    print(line.toString().replaceAll(RegExp(r' +$'), ''));
  }
}

class _CollectorStdio2 implements Stdio {
  final StringBuffer _buf = StringBuffer();
  int _termCols = 100;

  _CollectorStdio2();

  String get collected => _buf.toString();
  void clear() => _buf.clear();

  @override
  void write(String s) => _buf.write(s);

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => _termCols;

  @override
  bool get hasTerminal => true;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}
