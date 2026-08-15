import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/stub_server.dart';

/// The stub provider server (`tool/stub_server.dart`) is what makes UI sweeps
/// deterministic: same scenario + same request → identical bytes, every run.
/// These tests pin that contract against the committed scenario files, so a
/// format change that would silently break old repros is caught here.
void main() {
  // `dart test` runs from the package root; Platform.script points at a temp
  // kernel snapshot, so resolve the scenarios dir from the cwd instead.
  final scenariosDir =
      p.join(Directory.current.path, 'tool', 'stub', 'scenarios');

  late HttpClient client;

  setUp(() => client = HttpClient());
  tearDown(() => client.close());

  /// POSTs once to a fresh server on an ephemeral port and returns the status
  /// and raw body bytes.
  Future<({int status, Uint8List body})> serveOnce(String scenario) async {
    final script = ScenarioScript.load(p.join(scenariosDir, '$scenario.txt'));
    final server = await StubServer.bind('127.0.0.1', 0, script);
    try {
      final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': 'stub-1',
        'messages': [
          {'role': 'user', 'content': 'hello'}
        ],
        'stream': true,
      }));
      final res = await req.close();
      final body = <int>[];
      await for (final chunk in res) {
        body.addAll(chunk);
      }
      return (status: res.statusCode, body: Uint8List.fromList(body));
    } finally {
      await server.close();
    }
  }

  test('every committed scenario parses and has at least one step', () {
    final names = Directory(scenariosDir)
        .listSync()
        .whereType<File>()
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
    expect(names, containsAll(<String>[
      'normal',
      'abort_midstream',
      'long_line',
      'emoji_cjk',
      'rapid_tool_calls',
      'empty',
      'error',
    ]));
    for (final n in names) {
      final script = ScenarioScript.load(p.join(scenariosDir, '$n.txt'));
      expect(script.steps, isNotEmpty, reason: n);
    }
  });

  test('normal scenario is a complete OpenAI SSE turn', () async {
    final res = await serveOnce('normal');
    expect(res.status, 200);
    final body = utf8.decode(res.body);
    expect(body, startsWith('data: {"choices"'));
    expect(body, contains('"finish_reason":"stop"'));
    expect(body, contains('"usage"'));
    expect(body.trimRight(), endsWith('data: [DONE]'));
  });

  test('same scenario replays byte-identical on repeat runs', () async {
    for (final scenario in ['normal', 'emoji_cjk', 'long_line', 'empty']) {
      final a = await serveOnce(scenario);
      final b = await serveOnce(scenario);
      expect(b.status, a.status);
      expect(b.body, equals(a.body),
          reason: '$scenario must replay identical bytes');
    }
  });

  test('error scenario returns its canned status and body, identically',
      () async {
    final a = await serveOnce('error');
    final b = await serveOnce('error');
    expect(a.status, 400);
    expect(utf8.decode(a.body), contains('"type":"invalid_request_error"'));
    expect(b.body, equals(a.body));
  });

  test('abort_midstream cuts the stream before any finish frame', () async {
    // The abort destroys the socket mid-tokens: the client sees a body that
    // simply ends — deltas arrived, but no finish frame and no [DONE].
    final res = await serveOnce('abort_midstream');
    final body = utf8.decode(res.body);
    expect(res.status, 200);
    expect(body, contains('"content":"Starting the answer'));
    expect(body, isNot(contains('finish_reason":"stop')));
    expect(body, isNot(contains('[DONE]')));
  });

  test('rapid_tool_calls streams three tool_use blocks in one turn', () async {
    final body = utf8.decode((await serveOnce('rapid_tool_calls')).body);
    expect(RegExp(r'"index":\d+,"id":"call_stub0[123]"').allMatches(body),
        hasLength(3));
    expect(body, contains('"finish_reason":"tool_calls"'));
  });

  test('steps advance per request and the last step repeats', () async {
    final script =
        ScenarioScript.load(p.join(scenariosDir, 'rapid_tool_calls.txt'));
    expect(script.steps, hasLength(2));
    expect(script.stepFor(0), same(script.steps[0]));
    expect(script.stepFor(1), same(script.steps[1]));
    expect(script.stepFor(2), same(script.steps[1]));
    expect(script.stepFor(99), same(script.steps[1]));
  });
}
