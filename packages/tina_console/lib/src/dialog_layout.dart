import '../tina_console.dart';

/// The original picker frame, clipped by terminal cells and sized for small
/// terminals. SGR styling stays intact at the border and clipping boundaries.
List<String> dialogBoxLines({
  required int width,
  required int height,
  required String title,
  required List<String> body,
  required String footer,
  required String Function(String) paint,
}) {
  if (width <= 0 || height <= 0) return [];
  if (width < 4 || height < 4) {
    return [title, ...body]
        .take(height)
        .map((line) => clipToVisibleColumns(line, width))
        .toList();
  }
  String clipped(String text, int cells) => clipToVisibleColumns(text, cells);
  final titleFit = clipped(' $title ', width - 2);
  final inner = width - 4;
  String row(String text) {
    final fit = clipped(text, inner);
    return '${paint('│')} $fit\x1b[0m${' ' * (inner - visibleWidth(fit))} ${paint('│')}';
  }

  final content = body.take(height - 4).toList();
  return [
    '${paint('┌')}${paint(titleFit)}${paint('─' * (width - 2 - visibleWidth(titleFit)))}${paint('┐')}',
    for (final line in content) row(line),
    for (var i = content.length; i < height - 3; i++) row(''),
    row(footer),
    '${paint('└')}${paint('─' * (width - 2))}${paint('┘')}',
  ];
}

/// Modal space includes the input row while the modal owns the keyboard.
Rect dialogArea(ScreenLayout layout) => Rect(
      row: layout.chat.row,
      col: layout.chat.col,
      width: layout.chat.width.clamp(0, layout.width),
      height: (layout.inputRow - layout.chat.row + 1).clamp(0, layout.height),
    );

Rect centeredDialog(ScreenLayout layout, List<String> lines) {
  final width = lines.fold(
      0, (n, line) => visibleWidth(line) > n ? visibleWidth(line) : n);
  return dialogBounds(layout,
      preferredWidth: width, preferredHeight: lines.length);
}

/// Allocate a centered modal rectangle independently of its current content.
/// Owners choose preferred dimensions; the viewport supplies the hard maximum.
/// Reuse the dimensions while editing and wrap/scroll within the returned bounds.
Rect dialogBounds(ScreenLayout layout,
    {required int preferredWidth, required int preferredHeight}) {
  final area = dialogArea(layout);
  final width = preferredWidth.clamp(0, area.width);
  final height = preferredHeight.clamp(0, area.height);
  return Rect(
      row: area.row + (area.height - height) ~/ 2,
      col: area.col + (area.width - width) ~/ 2,
      width: width,
      height: height);
}

String clipDialogText(String text, int width) {
  if (width <= 0) return '';
  text = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  if (visibleWidth(text) <= width) return text;
  var columns = 0;
  var index = 0;
  while (index < text.length) {
    final next = runeWidth(codePointAt(text, index));
    if (columns + next > width - 1) break;
    columns += next;
    index += runeSizeAt(text, index);
  }
  return '${text.substring(0, index)}…';
}

List<String> wrapDialogText(String text, int width) {
  if (width <= 0) return [];
  text = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  final lines = <String>[];
  var row = StringBuffer();
  var columns = 0;
  for (var i = 0; i < text.length;) {
    final size = runeSizeAt(text, i);
    final next = runeWidth(codePointAt(text, i));
    if (columns + next > width && row.isNotEmpty) {
      lines.add(row.toString());
      row = StringBuffer();
      columns = 0;
    }
    row.write(text.substring(i, i + size));
    columns += next;
    i += size;
  }
  lines.add(row.toString());
  return lines;
}

/// Wrap explanatory prose at word boundaries. Commands, paths and diffs use
/// [wrapDialogText] to retain every literal character instead.
List<String> wrapDialogWords(String text, int width) {
  if (width <= 0) return [];
  final result = <String>[];
  for (final paragraph in text.split('\n')) {
    var line = '';
    for (final word
        in paragraph.split(RegExp(r'\s+')).where((s) => s.isNotEmpty)) {
      if (line.isNotEmpty && visibleWidth('$line $word') > width) {
        result.add(line);
        line = '';
      }
      if (visibleWidth(word) > width) {
        final pieces = wrapDialogText(word, width);
        result.addAll(pieces.take(pieces.length - 1));
        line = pieces.last;
      } else {
        line = line.isEmpty ? word : '$line $word';
      }
    }
    result.add(line);
  }
  return result;
}
