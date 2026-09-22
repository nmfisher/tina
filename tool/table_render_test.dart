import 'dart:io';
import 'package:tina/chat/markdown_renderer.dart';

void main() {
  const source = '''
| Name | Value |
|------|-------|
| Foo  | 1     |
| Bar  | 2     |
''';

  final lines = renderMarkdown(source, MarkdownStyle());
  print('Rendered table:');
  for (final line in lines) {
    for (final run in line.runs) {
      stdout.write(run.text);
    }
    stdout.write('\n');
  }
}
