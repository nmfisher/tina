import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Stage-1 pipe verification, deterministic: the headless engine runs as a
/// subprocess over stdio (`--pipes`), driven by JSON lines, against a local
/// stub provider. Exercises exactly the exit test the wasm stage needs:
/// a full turn with a provider call, a tool call and a file edit; a
/// mid-turn cancellation the engine observes; and a second turn after the
/// cancel. Every committed entry that crosses the pipe must round-trip
/// through [SessionEntry.fromJson] — the serialization proof.
void main() {
  test(
    'pipes: full turn with tool edit, mid-turn cancel, second turn',
    () async {
      final directory = Directory.systemTemp.createTempSync('tina-pipes-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        child?.kill(ProcessSignal.sigkill);
        await server.close(force: true);
        directory.deleteSync(recursive: true);
      });

      const toolPath = 'hello-pipes.txt';
      const toolContent = 'written over pipes\n';
      var requests = 0;
      final hung = Completer<void>();
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final index = requests++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        Future<void> send(Object delta, {String finish = 'stop'}) async {
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {'index': 0, 'delta': delta, 'finish_reason': finish},
              ],
            })}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        }

        switch (index) {
          case 0: // Turn 1, round 1: ask for the write tool.
            await send({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'write-1',
                  'type': 'function',
                  'function': {
                    'name': 'write',
                    'arguments': jsonEncode({
                      'filePath': '${directory.path}/$toolPath',
                      'content': toolContent,
                    }),
                  },
                },
              ],
            }, finish: 'tool_calls');
          case 1: // Turn 1, round 2: the tool result came back; finish.
            expect(
              (body['messages'] as List).any((m) => m['role'] == 'tool'),
              isTrue,
              reason: 'round 2 must follow the executed tool result',
            );
            await send({'content': 'file written'});
          case 2: // Turn 2: hold the stream open until it is cancelled.
            request.response.write(': holding\n\n');
            await request.response.flush();
            hung.complete();
          default: // Turn 3 and later: a plain reply.
            await send({'content': 'PONG'});
        }
      });

      final config = File('${directory.path}/config')
        ..writeAsStringSync('''
[default]
provider = "local"
model = "stub"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["stub"]
[plugins]
enabled = ["tina/persistence"]
''');

      var root = Directory.current;
      while (!File('${root.path}/bin/tina.dart').existsSync()) {
        if (root.parent.path == root.path) {
          throw StateError('Cannot locate the CLI application');
        }
        root = root.parent;
      }
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/tina.dart',
        '--config',
        config.path,
        '--cwd',
        directory.path,
        '--no-sandbox',
        '--yolo',
        '--pipes',
      ], workingDirectory: root.path);
      child = process;
      final transcript = <String>[];
      final stderrText = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(stderrText.write);
      final events = <Map<String, dynamic>>[];
      final waiters =
          <
            bool Function(Map<String, dynamic>),
            Completer<Map<String, dynamic>>
          >{};
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            transcript.add(line);
            final event = jsonDecode(line) as Map<String, dynamic>;
            events.add(event);
            for (final entry in waiters.entries.toList()) {
              if (entry.key(event) && !entry.value.isCompleted) {
                entry.value.complete(event);
              }
            }
          });

      Future<Map<String, dynamic>> waitFor(
        String what,
        bool Function(Map<String, dynamic>) predicate, {
        Duration timeout = const Duration(seconds: 30),
      }) {
        final seen = events.where(predicate).firstOrNull;
        if (seen != null) return Future.value(seen);
        final completer = Completer<Map<String, dynamic>>();
        waiters[predicate] = completer;
        return completer.future.timeout(
          timeout,
          onTimeout: () {
            throw StateError(
              'timed out waiting for $what; events so far:\n'
              '${transcript.take(60).join('\n')}\nstderr: $stderrText',
            );
          },
        );
      }

      void send(Map<String, dynamic> request) =>
          process.stdin.writeln(jsonEncode(request));

      /// Every committed entry must survive the pipe: decode through the
      /// engine's own serializer and re-encode to the same JSON. One known
      /// convention: `toJson` omits `seq` for the unstamped/zero position
      /// (`seq > 0` guard in SessionEntry), and `fromJson` reads a missing
      /// `seq` as 0 — so the zero position round-trips semantically, without
      /// the redundant key. The envelope carries `seq` regardless.
      void checkEntryRoundTrip(Map<String, dynamic> event) {
        expect(event['type'], 'entry');
        final wire = Map<String, dynamic>.from(event['entry'] as Map);
        // Host-added projection metadata is not part of the entry itself.
        wire.remove('features');
        wire.remove('unavailable_features');
        final decoded = SessionEntry.fromJson(Map<String, dynamic>.from(wire));
        expect(decoded.seq, wire['seq'], reason: 'seq must survive the wire');
        final expected = Map<String, dynamic>.of(wire);
        if (decoded.seq == 0) expected.remove('seq');
        expect(
          decoded.toJson(),
          equals(expected),
          reason: 'entry must round-trip: $wire',
        );
      }

      // The engine comes up and announces itself. Cold start (build hooks,
      // JIT) can take a while under a loaded suite; the protocol waits
      // below stay at 30s.
      final ready = await waitFor(
        'ready',
        (e) => e['type'] == 'ready',
        timeout: const Duration(seconds: 90),
      );
      expect(
        ready['session'],
        isA<String>().having((s) => s.length, 'len', greaterThan(0)),
      );
      expect(ready['model'], 'local/stub');

      // Turn 1: provider call, tool call, file edit.
      send({'op': 'submit', 'id': 'c1', 'line': 'write the file'});
      final running = await waitFor(
        'c1 running',
        (e) =>
            e['type'] == 'receipt' &&
            e['id'] == 'c1' &&
            e['state'] == 'running' &&
            e['workId'] != null,
      );
      expect(running['workId'], isNotNull);
      final toolUse = await waitFor(
        'write tool call',
        (e) =>
            e['type'] == 'entry' &&
            e['entry']['type'] == 'message_appended' &&
            _hasToolUse(e['entry']['message'], 'write'),
      );
      final call = _firstToolUse(toolUse['entry']['message'], 'write')!;
      expect(call['input']['filePath'], '${directory.path}/$toolPath');
      final toolResult = await waitFor(
        'write tool result',
        (e) =>
            e['type'] == 'entry' &&
            e['entry']['type'] == 'message_appended' &&
            _hasToolResult(e['entry']['message'], call['id'] as String),
      );
      final result = _firstToolResult(
        toolResult['entry']['message'],
        call['id'] as String,
      )!;
      expect(
        result['is_error'],
        isNot(true),
        reason:
            'the write must run (yolo, workspace path); '
            'result: ${result['content']}',
      );
      await waitFor(
        'c1 completed',
        (e) =>
            e['type'] == 'receipt' &&
            e['id'] == 'c1' &&
            e['state'] == 'completed',
      );
      await waitFor(
        'turn 1 ended',
        (e) =>
            e['type'] == 'entry' &&
            e['entry']['type'] == 'turn_ended' &&
            e['entry']['reason'] == 'complete',
      );
      final edited = File('${directory.path}/$toolPath');
      expect(
        edited.readAsStringSync(),
        toolContent,
        reason: 'the file edit must land on disk',
      );
      checkEntryRoundTrip(toolUse);
      checkEntryRoundTrip(toolResult);

      // Turn 2: cancel mid-turn while the provider stream hangs.
      send({'op': 'submit', 'id': 'c2', 'line': 'hold this turn'});
      final c2running = await waitFor(
        'c2 running',
        (e) =>
            e['type'] == 'receipt' &&
            e['id'] == 'c2' &&
            e['state'] == 'running' &&
            e['workId'] != null,
      );
      await hung.future.timeout(const Duration(seconds: 30));
      await waitFor(
        'status shows the turn work',
        (e) => e['type'] == 'status' && (e['work'] as List).isNotEmpty,
      );
      send({
        'op': 'cancel',
        'work': c2running['workId'],
        'reason': 'stage-1 cancel probe',
      });
      final cancelAccepted = await waitFor(
        'cancel accepted',
        (e) => e['type'] == 'cancel' && e['work'] == c2running['workId'],
      );
      expect(cancelAccepted['accepted'], isTrue);
      await waitFor(
        'c2 cancelled',
        (e) =>
            e['type'] == 'receipt' &&
            e['id'] == 'c2' &&
            e['state'] == 'cancelled',
      );
      await waitFor(
        'turn 2 ended cancelled',
        (e) =>
            e['type'] == 'entry' &&
            e['entry']['type'] == 'turn_ended' &&
            e['entry']['reason'] == 'cancelled',
      );
      final idle = await waitFor(
        'engine idle after cancel',
        (e) => e['type'] == 'status' && e['running'] == false && !e['busy'],
      );
      expect(idle['closed'], isNot(true));

      // Turn 3: the engine still works after the cancellation.
      send({'op': 'submit', 'id': 'c3', 'line': 'reply PONG'});
      final pong = await waitFor(
        'final assistant text',
        (e) =>
            e['type'] == 'entry' &&
            e['entry']['type'] == 'message_appended' &&
            e['entry']['message']['role'] == 'assistant' &&
            _textContent(e['entry']['message']).contains('PONG'),
      );
      checkEntryRoundTrip(pong);
      await waitFor(
        'c3 completed',
        (e) =>
            e['type'] == 'receipt' &&
            e['id'] == 'c3' &&
            e['state'] == 'completed',
      );

      // Every entry that crossed the pipe round-trips.
      for (final event in events.where((e) => e['type'] == 'entry').toList()) {
        checkEntryRoundTrip(event);
      }

      send({'op': 'shutdown'});
      await waitFor('bye', (e) => e['type'] == 'bye');
      expect(
        await process.exitCode.timeout(const Duration(seconds: 15)),
        0,
        reason: 'clean shutdown after bye\nstderr: $stderrText',
      );
      expect(requests, 4, reason: 'turn 2 made exactly one provider call');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Process? child;

Map<String, dynamic>? _firstToolUse(Map message, String name) {
  for (final block in message['content'] as List) {
    if (block is Map && block['type'] == 'tool_use' && block['name'] == name) {
      return Map<String, dynamic>.from(block);
    }
  }
  return null;
}

bool _hasToolUse(Map message, String name) =>
    _firstToolUse(message, name) != null;

Map<String, dynamic>? _firstToolResult(Map message, String toolUseId) {
  for (final block in message['content'] as List) {
    if (block is Map &&
        block['type'] == 'tool_result' &&
        block['tool_use_id'] == toolUseId) {
      return Map<String, dynamic>.from(block);
    }
  }
  return null;
}

bool _hasToolResult(Map message, String toolUseId) =>
    _firstToolResult(message, toolUseId) != null;

String _textContent(Map message) => [
  for (final block in message['content'] as List)
    if (block is Map && block['type'] == 'text') block['text'] as String,
].join();
