import 'package:markdown/markdown.dart' as md;

void main() {
  const source = '''
| Name | Value |
|------|-------|
| Foo  | 1     |
| Bar  | 2     |
''';

  final doc = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  final nodes = doc.parse(source);
  print('--- gitHubFlavored ---');
  for (final node in nodes) {
    print('Node type: ${node.runtimeType}, tag: ${(node as md.Element).tag}');
  }
}
