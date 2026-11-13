import 'dart:async';

import 'console_contribution.dart';
import 'input_event.dart';
import 'modal_surface.dart';
import 'rect.dart';
import 'region.dart';
import 'renderer.dart';
import 'term_width.dart';

/// Snapshot-backed selection. Appends and history eviction cannot change the
/// text being copied while the pointer scrolls beyond the viewport.
final class MouseTextSelection extends ModalSurface {
  MouseTextSelection(this.context, {required this.copyText});
  final ConsoleContext context;
  final Future<bool> Function(String text) copyText;
  OverlayRegion? _overlay;
  Timer? _scrollTimer, _noticeTimer;
  List<String> _lines = const [];
  List<String> _displayLines = const [];
  Rect _bounds = Rect.empty;
  int _top = 0, _initialOffset = 0;
  (int, int)? _anchor, _end;
  MouseEvent? _pointer;
  bool _dragging = false, _moved = false, _closed = false;
  String? _notice;
  Future<void> _copyTail = Future.value();
  int _generation = 0;

  @override
  bool get isActive => _dragging;
  List<RenderLine> status() => [
        if (_dragging || _notice != null)
          RenderLine(runs: [
            RenderRun(_dragging ? 'Release to copy · Esc cancel' : _notice!,
                context.screen.theme.chat.dim)
          ]),
      ];

  @override
  bool handleEvent(InputEvent event) {
    if (_closed) return false;
    if (context.isReadingKey || !context.isActive) {
      cancel();
      return false;
    }
    if (event is! MouseEvent) {
      if (!_dragging) return false;
      if (event is ScrollEvent) {
        _scroll(event.up ? -1 : 1);
        return true;
      }
      cancel();
      return event is EscapeKey;
    }
    if (event.action == MouseAction.hover) {
      // Button-up motion also recovers from a release outside the window.
      final active = _dragging;
      cancel();
      return active;
    }
    if (event.action == MouseAction.release) {
      if (!_dragging) return false;
      _extend(event);
      final selected = _moved ? selectedText : '';
      final generation = ++_generation;
      _finish();
      if (selected.isNotEmpty) {
        _copyTail = _copyTail.then((_) async {
          var copied = false;
          try {
            copied = await copyText(selected);
          } catch (_) {}
          if (_closed || generation != _generation) return;
          _notice = copied
              ? 'Copied ${selected.split('\n').length} lines'
              : 'Could not copy selection to clipboard';
          _noticeTimer?.cancel();
          _noticeTimer = Timer(const Duration(seconds: 3), () {
            _notice = null;
            context.refreshStatus();
          });
          context.refreshStatus();
        });
      }
      return true;
    }
    if (!_dragging) {
      if (event.action != MouseAction.press || context.isCompleting)
        return false;
      final chat = context.chat;
      _bounds = Rect(
          row: chat.bounds.row,
          col: chat.bounds.col,
          width: chat.bounds.width,
          height: chat.usableHeight);
      if (!_bounds.containsCell(event.row, event.col)) return false;
      _displayLines = List.unmodifiable(chat.snapshotLines());
      _lines = List.unmodifiable(_displayLines.map(_plain));
      if (_lines.isEmpty) return false;
      _initialOffset = chat.scrollOffset;
      _top = _lines.length - _bounds.height - _initialOffset;
      if (_top + event.row - _bounds.row < 0) return false;
      final point = _point(event);
      if (point == null) return false;
      _generation++;
      _notice = null;
      _anchor = _end = point;
      _pointer = event;
      _moved = false;
      _dragging = true;
      _overlay = OverlayRegion(context.screen, _bounds);
      _paint();
      context.refreshStatus();
      return true;
    }
    _extend(event);
    return true;
  }

  (int, int)? _point(MouseEvent event) {
    final row = (_top + (event.row - _bounds.row).clamp(0, _bounds.height - 1))
        .clamp(0, _lines.length - 1);
    return (row, (event.col - _bounds.col).clamp(0, _bounds.width - 1));
  }

  void _extend(MouseEvent event) {
    _pointer = event;
    _end = _point(event);
    _moved = _moved || _end != _anchor;
    _paint();
    final outside = event.row <= _bounds.row || event.row >= _bounds.bottom;
    if (outside && _scrollTimer == null) {
      _scrollTimer =
          Timer.periodic(const Duration(milliseconds: 80), (_) => autoScroll());
    } else if (!outside) {
      _scrollTimer?.cancel();
      _scrollTimer = null;
    }
  }

  /// One tick, also exposed for deterministic edge-scrolling tests.
  void autoScroll() {
    if (!_dragging) return;
    if (context.isReadingKey ||
        !context.isActive ||
        context.chat.bounds.width != _bounds.width ||
        context.chat.usableHeight != _bounds.height ||
        context.chat.bounds.row != _bounds.row ||
        context.chat.bounds.col != _bounds.col) {
      cancel();
      return;
    }
    final pointer = _pointer!;
    if (pointer.row <= _bounds.row) {
      _scroll(-1 - ((_bounds.row - pointer.row) ~/ 2).clamp(0, 7));
    } else if (pointer.row >= _bounds.bottom) {
      _scroll(1 + ((pointer.row - _bounds.bottom) ~/ 2).clamp(0, 7));
    }
  }

  void _scroll(int delta) {
    if (_lines.length <= _bounds.height) return;
    final next = (_top + delta).clamp(0, _lines.length - _bounds.height);
    if (next == _top) {
      _scrollTimer?.cancel();
      _scrollTimer = null;
      return;
    }
    _top = next;
    _end = _point(_pointer!);
    _moved = true;
    _paint();
  }

  ((int, int), (int, int)) get _range {
    final a = _anchor!, b = _end!;
    return a.$1 < b.$1 || a.$1 == b.$1 && a.$2 <= b.$2 ? (a, b) : (b, a);
  }

  String get selectedText {
    if (_anchor == null || _end == null) return '';
    final (start, end) = _range;
    return [
      for (var row = start.$1; row <= end.$1; row++)
        _slice(_lines[row], row == start.$1 ? start.$2 : 0,
            row == end.$1 ? end.$2 + 1 : null)
    ].join('\n');
  }

  void _paint() {
    final (start, end) = _range;
    _overlay?.update(bounds: _bounds, lines: [
      for (var r = 0; r < _bounds.height; r++)
        if (_top + r < 0 || _top + r >= _lines.length)
          ''
        else if (!_moved || _top + r < start.$1 || _top + r > end.$1)
          _displayLines[_top + r]
        else
          _highlight(_lines[_top + r], _top + r == start.$1 ? start.$2 : 0,
              _top + r == end.$1 ? end.$2 + 1 : _bounds.width),
    ]);
  }

  void _finish() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    if (_dragging) {
      final offset =
          (_lines.length - _bounds.height - _top).clamp(0, _lines.length);
      context.chat.scrollBy(_initialOffset - offset);
    }
    _dragging = false;
    _overlay?.dispose();
    _overlay = null;
    _anchor = _end = null;
    _lines = const [];
    _displayLines = const [];
    context.refreshStatus();
    context.refreshInput();
  }

  void cancel() {
    if (_dragging) {
      _generation++;
      _finish();
    }
  }

  void close() {
    cancel();
    _closed = true;
    _noticeTimer?.cancel();
  }
}

String _plain(String text) => text
    .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '')
    .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');

int _index(String text, int column) {
  var col = 0, i = 0;
  while (i < text.length) {
    final size = runeSizeAt(text, i), width = runeWidth(codePointAt(text, i));
    if (col + width > column) break;
    col += width;
    i += size;
  }
  return i;
}

String _slice(String text, int start, int? end) => text.substring(
    _index(text, start), end == null ? text.length : _endIndex(text, end));
int _endIndex(String text, int column) {
  final i = _index(text, column);
  if (i >= text.length || plainWidth(text.substring(0, i)) >= column) return i;
  var end = i + runeSizeAt(text, i);
  while (end < text.length && runeWidth(codePointAt(text, end)) == 0) {
    end += runeSizeAt(text, end);
  }
  return end;
}

String _highlight(String text, int start, int end) {
  final from = _index(text, start), to = _endIndex(text, end);
  // Explicit colours work on both ANSI and notcurses (SGR inverse does not).
  return '${text.substring(0, from)}\x1b[30;47m${text.substring(from, to)}\x1b[0m${text.substring(to)}';
}
