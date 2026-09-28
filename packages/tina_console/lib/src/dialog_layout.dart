import '../tina_console.dart';

/// Modal space includes the input row while the modal owns the keyboard.
Rect dialogArea(ScreenLayout layout) => Rect(
      row: layout.chat.row,
      col: layout.chat.col,
      width: layout.chat.width.clamp(0, layout.width),
      height: (layout.inputRow - layout.chat.row + 1).clamp(0, layout.height),
    );

Rect centeredDialog(ScreenLayout layout, List<String> lines) {
  final area = dialogArea(layout);
  final width = lines
      .fold(0, (n, line) => visibleWidth(line) > n ? visibleWidth(line) : n)
      .clamp(0, area.width);
  final height = lines.length.clamp(0, area.height);
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
