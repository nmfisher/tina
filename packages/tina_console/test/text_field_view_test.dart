import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

void main() {
  test('numeric cursor follows digits across formatting boundaries', () {
    var input = const TextLineInput(buffer: '1234567', cursor: 1);
    expect(textFieldView(input, width: 20, numeric: true),
        (text: '1,234,567', cursorColumn: 2));
    input = input.deleteForward().insert('9');
    expect(input.buffer, '1934567');
    expect(textFieldView(input, width: 20, numeric: true).cursorColumn, 3);
    input = input.moveEnd();
    expect(textFieldView(input, width: 20, numeric: true),
        (text: '1,934,567 ', cursorColumn: 9));
    expect(textFieldView(input, width: 5, numeric: true),
        (text: ',567 ', cursorColumn: 4));
    expect(textFieldView(input.moveHome(), width: 5, numeric: true),
        (text: '1,934', cursorColumn: 0));
  });

  test('wide and masked input use terminal cells, without leaking controls',
      () {
    const input = TextLineInput(buffer: 'a😀界z', cursor: 4);
    expect(textFieldView(input, width: 20), (text: 'a😀界z', cursorColumn: 5));
    expect(textFieldView(input, width: 3), (text: '界z', cursorColumn: 2));
    expect(textFieldView(input, width: 20, secret: true),
        (text: '••••', cursorColumn: 3));
    const pasted = TextLineInput(buffer: '\x1b[31mred\x1b[0m\nend', cursor: 12);
    final view = textFieldView(pasted, width: 20);
    expect(view.text, 'red end');
    expect(view.text, isNot(contains('\x1b')));
  });
}
