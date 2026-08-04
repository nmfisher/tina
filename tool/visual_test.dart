/// Minimal ANSI terminal emulator that renders TUI output to a text grid.
/// Run with: dart run tool/visual_test.dart
library;

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/panel_renderer.dart';

/// A virtual terminal screen that interprets basic ANSI escape sequences.
class VirtualTerminal {
  final int width;
  final int height;
  late final List<List<String>> _grid;
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _pendingWrap = false;

  VirtualTerminal({required this.width, required this.height}) {
    _grid = List.generate(height, (_) => List.filled(width, ' '));
  }

  void feed(String s) {
    var i = 0;
    while (i < s.length) {
      if (s[i] == '\x1b') {
        i = _handleEscape(s, i);
      } else if (s[i] == '\r') {
        _cursorCol = 0;
        _pendingWrap = false;
        i++;
      } else if (s[i] == '\n') {
        _cursorRow++;
        _pendingWrap = false;
        i++;
      } else {
        _putChar(s[i]);
        i++;
      }
    }
  }

  void _putChar(String ch) {
    if (_pendingWrap) {
      _cursorCol = 0;
      _cursorRow++;
      _pendingWrap = false;
    }
    if (_cursorRow >= 0 &&
        _cursorRow < height &&
        _cursorCol >= 0 &&
        _cursorCol < width) {
      _grid[_cursorRow][_cursorCol] = ch;
      _cursorCol++;
      if (_cursorCol >= width) {
        _pendingWrap = true;
        _cursorCol = width - 1; // stay at last col until next char
      }
    }
  }

  int _handleEscape(String s, int start) {
    if (start + 1 >= s.length) return start + 1;
    if (s[start + 1] == '7' || s[start + 1] == '8') return start + 2;
    if (s[start + 1] == '[') return _handleCsi(s, start);
    // \x1b[? prefix
    if (s[start + 1] == 'O') return start + 3;
    return start + 2;
  }

  int _handleCsi(String s, int start) {
    var j = start + 2;
    // Handle ? prefix (DEC private)
    if (j < s.length && s[j] == '?') j++;
    final buf = StringBuffer();
    while (j < s.length &&
        (s[j].codeUnitAt(0) >= 0x30 &&
                s[j].codeUnitAt(0) <= 0x3f ||
            s[j] == ';')) {
      buf.write(s[j]);
      j++;
    }
    if (j >= s.length) return j;
    final params = buf.toString();
    final cmd = s[j];
    j++;

    switch (cmd) {
      case 'G':
        _cursorCol = int.parse(params.isEmpty ? '1' : params) - 1;
        _pendingWrap = false;
      case 'H':
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
      case 'J':
        final n = params.isEmpty ? '0' : params;
        if (n == '2') _clearScreen();
      case 'K':
        final n = params.isEmpty ? '0' : params;
        if (n == '0') {
          for (var c = _cursorCol; c < width; c++) {
            _grid[_cursorRow][c] = ' ';
          }
        }
      case 'X':
        final n = params.isEmpty ? 1 : int.parse(params);
        for (var k = 0; k < n && _cursorCol + k < width; k++) {
          _grid[_cursorRow][_cursorCol + k] = ' ';
        }
      case 'A':
        _cursorRow -= params.isEmpty ? 1 : int.parse(params);
      case 'B':
        _cursorRow += params.isEmpty ? 1 : int.parse(params);
      case 'C':
        _cursorCol += params.isEmpty ? 1 : int.parse(params);
      case 'm':
        break;
      case 'h':
      case 'l':
        break;
    }
    return j;
  }

  void _clearScreen() {
    for (var r = 0; r < height; r++) {
      for (var c = 0; c < width; c++) {
        _grid[r][c] = ' ';
      }
    }
    _cursorRow = 0;
    _cursorCol = 0;
  }

  String render() {
    final sb = StringBuffer();
    for (var r = 0; r < height; r++) {
      final line = _grid[r].join('');
      sb.writeln(line.replaceAll(RegExp(r' +$'), ''));
    }
    return sb.toString();
  }
}

void main() {
  const termWidth = 100;
  const termHeight = 20;

  final vt = VirtualTerminal(width: termWidth, height: termHeight);
  final fakeIo = _CollectorStdio();
  final layout = PanelLayout.fromWidth(termWidth);
  final chatRenderer = PanelRenderer(
    layout: layout,
    left: true,
    io: fakeIo,
    ansi: AnsiCapable.yes,
  )..rawMode = true;

  final lw = layout.leftWidth;
  final rw = layout.rightWidth;

  // === Frame ===
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
  vt.feed(frameSb.toString());

  // Position cursor at first content row
  vt.feed('\x1b[2;3H');

  // === Greeting via left PanelRenderer ===
  fakeIo.clear();
  chatRenderer.write(
      '\x1b[36mtina\x1b[0m — /help · /exit · /clear · /compact · /model · /permissions · /sessions · /resume. ESC cancels a turn.\n');
  vt.feed(fakeIo.collected);

  fakeIo.clear();
  chatRenderer.dim('session: 20260526-abc\n');
  vt.feed(fakeIo.collected);

  // === Position input at bottom ===
  vt.feed('\x1b[${termHeight - 2};1H');

  fakeIo.clear();
  chatRenderer.drawSeparator();
  vt.feed(fakeIo.collected);

  vt.feed('\x1b[${termHeight - 1};3H');

  fakeIo.clear();
  chatRenderer.write('> ');
  vt.feed(fakeIo.collected);

  // === Right panel spinner ===
  vt.feed(
      '\x1b7\x1b[1G│\x1b[${layout.dividerCol + 1}G│\x1b[${layout.rightStart + 1}G\x1b[${rw}X\x1b[2m⠋ thinking…\x1b[0m\x1b[${termWidth}G│\x1b8');

  print('=== TUI Visual Snapshot (${termWidth}x${termHeight}) ===');
  print(vt.render());
  print('=== End ===');
}

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
