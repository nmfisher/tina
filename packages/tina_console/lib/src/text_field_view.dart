import 'input_display.dart';
import 'term_width.dart';
import 'text_line_input.dart';

/// Group a displayed integer without changing the value used for storage.
String formatInteger(int value) => groupDigits(value.toString());

String groupDigits(String digits) =>
    digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// A single-row viewport and the hardware cursor's cell within it.
/// Editing indices stay in the original buffer, independent of commas,
/// masked credentials, wide characters and horizontal scrolling.
({String text, int cursorColumn}) textFieldView(TextLineInput input,
    {required int width, bool secret = false, bool numeric = false}) {
  if (width <= 0) return (text: '', cursorColumn: 0);
  String text;
  int cursor;
  if (secret) {
    text = '•' * input.buffer.runes.length;
    cursor = input.buffer.substring(0, input.cursor).runes.length;
  } else if (numeric && RegExp(r'^\d*$').hasMatch(input.buffer)) {
    text = groupDigits(input.buffer);
    // Count only separators preceding the next editable digit.
    cursor = 0;
    var digits = 0;
    while (cursor < text.length && digits < input.cursor) {
      if (text[cursor] != ',') digits++;
      cursor++;
    }
    if (cursor < text.length && text[cursor] == ',') cursor++;
  } else {
    text = inputDisplayText(input.buffer);
    cursor = inputDisplayText(input.buffer.substring(0, input.cursor)).length;
  }
  final before = text.substring(0, cursor).runes.toList();
  var columns = before.fold(0, (n, rune) => n + runeWidth(rune));
  var start = 0;
  // Reserve a cell for the cursor even when it follows the last character.
  while (start < before.length && columns >= width) {
    columns -= runeWidth(before[start++]);
  }
  final visible = StringBuffer(String.fromCharCodes(before.skip(start)));
  var used = columns;
  for (final rune in text.substring(cursor).runes) {
    final cells = runeWidth(rune);
    if (used + cells > width) break;
    visible.writeCharCode(rune);
    used += cells;
  }
  if (used == columns) visible.write(' ');
  return (text: visible.toString(), cursorColumn: columns);
}
