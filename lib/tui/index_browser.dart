import 'dart:async';

import 'package:tina_app/classification.dart';
import 'package:tina_console/tina_console.dart';

import 'spawn_overlay.dart' show modalTakeFocus, modalRestoreFocus;

/// A snapshot browser, using the same full-screen surface and input lease as
/// the workflow/output viewers. It never appends frames to chat scrollback.
Future<void> runIndexBrowser({
  required Screen screen,
  required LineEditor editor,
  required IndexView view,
  Future<void>? cancelSignal,
  Future<InputEvent> Function()? readEvent,
}) async {
  final read = readEvent ?? editor.captureKeyReader();
  final stop = cancelSignal?.then<InputEvent>((_) => EscapeKey());
  final previous = modalTakeFocus(editor);
  final overlay = OverlayRegion(
    screen,
    Rect(
      row: 0,
      col: 0,
      width: screen.layout.width,
      height: screen.layout.height,
    ),
  );
  final expanded = <String>{'.'};
  var selected = '.';
  var offset = 0;
  var detail = false;
  var detailRow = 0;
  var detailCol = 0;
  final detailCache = <String, List<String>>{};

  List<({String path, int depth})> rows() {
    final result = <({String path, int depth})>[];
    void visit(String path, int depth) {
      result.add((path: path, depth: depth));
      if (expanded.contains(path)) {
        for (final child in view.directories[path]!.children) {
          visit(child, depth + 1);
        }
      }
    }

    if (view.directories.containsKey('.')) visit('.', 0);
    return result;
  }

  // Saved explanations and filenames are plain text, never terminal escapes.
  String plain(String text) =>
      text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
  String crop(String text, int width, [int start = 0]) {
    final runes = plain(text).runes.skip(start).take(width).toList();
    return String.fromCharCodes(runes);
  }

  try {
    while (true) {
      final layout = screen.layout;
      final width = layout.width.clamp(1, 100000);
      final height = layout.height.clamp(1, 100000);
      final page = (height - 5).clamp(1, height);
      final visible = rows();
      if (visible.isEmpty) return;
      final focus = visible
          .indexWhere((r) => r.path == selected)
          .clamp(0, visible.length - 1);
      selected = visible[focus].path;
      final directory = view.directories[selected]!;
      final details = detail
          ? detailCache.putIfAbsent(
              selected,
              () => directory.details.split('\n'),
            )
          : const <String>[];
      final lines = <String>[
        crop(
          detail
              ? 'Index — $selected'
              : 'Index — saved directory classifications',
          width,
        ),
        crop(
          view.warning ??
              'Input freshness only · no classifier calls · reopen to refresh',
          width,
        ),
      ];
      if (detail) {
        detailRow = detailRow.clamp(
          0,
          (details.length - page).clamp(0, details.length),
        );
        final maxWidth = details.fold<int>(
          0,
          (n, s) => s.runes.length > n ? s.runes.length : n,
        );
        detailCol = detailCol.clamp(0, (maxWidth - width).clamp(0, maxWidth));
        for (var i = 0; i < page; i++) {
          lines.add(
            detailRow + i < details.length
                ? crop(details[detailRow + i], width, detailCol)
                : '',
          );
        }
      } else {
        if (focus < offset) offset = focus;
        if (focus >= offset + page) offset = focus - page + 1;
        offset = offset.clamp(
          0,
          (visible.length - page).clamp(0, visible.length),
        );
        for (var i = 0; i < page; i++) {
          if (offset + i >= visible.length) {
            lines.add('');
            continue;
          }
          final row = visible[offset + i];
          final node = view.directories[row.path]!;
          final marker = node.children.isEmpty
              ? ' '
              : expanded.contains(row.path)
              ? '▾'
              : '▸';
          final label = row.path == '.' ? './' : '${row.path.split('/').last}/';
          lines.add(
            crop(
              '${row.path == selected ? '>' : ' '} ${'  ' * row.depth}$marker $label  ${node.summary}',
              width,
            ),
          );
        }
      }
      lines.add(crop(directory.path, width));
      lines.add(
        crop(
          detail
              ? '↑↓/PgUp/PgDn scroll · ←→ pan · enter tree · esc close'
              : '↑↓ move · ←→ fold/open · enter details · esc close',
          width,
        ),
      );
      overlay.update(
        bounds: Rect(row: 0, col: 0, width: width, height: height),
        lines: lines,
      );

      final event = await (stop == null ? read() : Future.any([read(), stop]));
      if (event is EscapeKey ||
          event is ControlKey && event.code == ControlCode.ctrlC)
        return;
      if (event is ControlKey && event.code == ControlCode.enter) {
        detail = !detail;
        detailRow = 0;
        detailCol = 0;
        continue;
      }
      int movement = 0;
      if (event is ScrollEvent) movement = event.up ? -3 : 3;
      if (event is ArrowKey) {
        switch (event.direction) {
          case ArrowDirection.up:
            movement = -1;
          case ArrowDirection.down:
            movement = 1;
          case ArrowDirection.pageUp:
            movement = -page;
          case ArrowDirection.pageDown:
            movement = page;
          case ArrowDirection.right:
            if (detail) {
              detailCol += 4;
            } else if (!expanded.add(selected) &&
                directory.children.isNotEmpty) {
              selected = directory.children.first;
            }
          case ArrowDirection.left:
            if (detail) {
              detailCol -= 4;
            } else if (!expanded.remove(selected) && selected != '.') {
              selected = selected.contains('/')
                  ? selected.substring(0, selected.lastIndexOf('/'))
                  : '.';
            }
        }
      }
      if (detail) {
        detailRow += movement;
      } else if (movement != 0) {
        selected =
            visible[(focus + movement).clamp(0, visible.length - 1)].path;
      }
    }
  } finally {
    overlay.hide();
    overlay.dispose();
    modalRestoreFocus(editor, previous);
  }
}
