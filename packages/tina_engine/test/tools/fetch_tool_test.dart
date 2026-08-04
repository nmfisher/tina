import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:tina_engine/tina_engine.dart';

/// Records the outgoing request, returns a scripted body + status.
class RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  String body;
  int status;
  String? contentType;

  RecordingClient({
    required this.body,
    this.status = 200,
    this.contentType = 'text/html; charset=utf-8',
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {
        if (contentType != null) 'content-type': contentType!,
      },
    );
  }
}

void main() {
  group('FetchTool request', () {
    test('GETs the url with an html Accept header', () async {
      final client = RecordingClient(body: '<p>hi</p>');
      final tool = FetchTool(client: client);

      await tool.execute({'url': 'https://example.com/docs'});

      expect(client.requests, hasLength(1));
      final req = client.requests.single;
      expect(req.method, 'GET');
      expect(req.url.toString(), 'https://example.com/docs');
      expect(req.headers['accept'], contains('text/html'));
    });

    test('non-html content-type is returned as-is, not converted',
        () async {
      final client = RecordingClient(
        body: '{"k": "v"}',
        contentType: 'application/json',
      );
      final tool = FetchTool(client: client);
      final r = await tool.execute({'url': 'https://api.example.com/x'});
      expect(r.isError, isFalse);
      expect(r.content, contains('"k"'));
    });

    test('non-200 status surfaces an error result', () async {
      final client = RecordingClient(body: 'nope', status: 404);
      final tool = FetchTool(client: client);
      final r = await tool.execute({'url': 'https://example.com/missing'});
      expect(r.isError, isTrue);
      expect(r.content, contains('404'));
    });
  });

  group('FetchTool input validation', () {
    test('missing/empty url is an error', () async {
      final tool = FetchTool(client: RecordingClient(body: ''));
      expect((await tool.execute({'url': ''})).isError, isTrue);
      expect((await tool.execute({})).isError, isTrue);
    });

    test('non-http schemes are rejected', () async {
      final tool = FetchTool(client: RecordingClient(body: ''));
      final r = await tool.execute({'url': 'ftp://host/file'});
      expect(r.isError, isTrue);
      expect(r.content, contains('http'));
    });

    test('max_chars truncates the result', () async {
      final client = RecordingClient(
        body: '<p>${'lorem ipsum ' * 500}</p>',
      );
      final tool = FetchTool(client: client);
      final r = await tool.execute(
          {'url': 'https://example.com/big', 'max_chars': 100});
      expect(r.isError, isFalse);
      expect(r.content, contains('truncated'));
      expect(r.content.length, lessThanOrEqualTo(200));
    });
  });

  group('htmlToMarkdown', () {
    test('converts headings, paragraph, code, and a list', () {
      const html = '''
<article>
  <h1>Install</h1>
  <p>Run <code>npm i</code> to begin.</p>
  <ul>
    <li>one</li>
    <li>two</li>
  </ul>
</article>
''';
      final md = htmlToMarkdown(html);
      expect(md, contains('# Install'));
      expect(md, contains('`npm i`'));
      expect(md, contains('- one'));
      expect(md, contains('- two'));
    });

    test('renders links and ordered lists', () {
      const html = '''
<p>See <a href="https://example.com">the docs</a>.</p>
<ol>
  <li>first</li>
  <li>second</li>
</ol>
''';
      final md = htmlToMarkdown(html);
      expect(md, contains('[the docs](https://example.com)'));
      expect(md, contains('1. first'));
      expect(md, contains('2. second'));
    });

    test('renders fenced code blocks with a language hint', () {
      const html = '''
<pre><code class="language-dart">
void main() {
  print('hi');
}
</code></pre>
''';
      final md = htmlToMarkdown(html);
      expect(md, contains('```dart'));
      expect(md, contains("print('hi');"));
      expect(md, contains('```'));
    });

    test('renders emphasis, bold, blockquote, and image', () {
      const html = '''
<p><em>italics</em> and <strong>bold</strong></p>
<blockquote><p>quote line</p></blockquote>
<img alt="diagram" src="https://img/d.png" />
''';
      final md = htmlToMarkdown(html);
      expect(md, contains('*italics*'));
      expect(md, contains('**bold**'));
      expect(md, contains('> quote line'));
      expect(md, contains('![diagram](https://img/d.png)'));
    });

    test('drops script and style content', () {
      const html = '''
<script>alert('x')</script>
<style>.x { color: red; }</style>
<p>visible</p>
''';
      final md = htmlToMarkdown(html);
      expect(md, contains('visible'));
      expect(md, isNot(contains('alert')));
      expect(md, isNot(contains('color: red')));
    });

    test('renders a simple table as pipe-delimited rows', () {
      const html = '''
<table>
  <tr><th>Name</th><th>Age</th></tr>
  <tr><td>Ada</td><td>36</td></tr>
</table>
''';
      final md = htmlToMarkdown(html);
      expect(md, contains('Name | Age'));
      expect(md, contains('Ada | 36'));
    });

    test('does not invent text for an empty body', () {
      expect(htmlToMarkdown('').trim(), isEmpty);
    });
  });
}
