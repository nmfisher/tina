// The pipes protocol's own contract, driven in process: no subprocess, no
// build hooks — an assembled session over injected byte streams, the same
// `runSessionPipes` the native `--pipes` mode and the wasm engine serve.
// Records for the transport-level guarantees: line decoding across chunk
// boundaries (the per-chunk UTF-8 bug) and the bounded outbound queue.
//
// Run: dart test test/pipes_protocol_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina/src/pipes.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// An assembly over a temp workspace whose provider plays [script], plus
/// the protocol running over injected streams. Returns the outbound event
/// list, the inbound controller and the process exit code future.
({
  SessionAssembly assembly,
  ScriptedProvider provider,
  StreamController<List<int>> input,
  List<Map<String, dynamic>> events,
  Future<int> exitCode,
}) _piped(
  List<List<StreamEvent>> script, {
  int? maxQueuedEvents,
  int? maxQueuedCharacters,
}) {
  final ws = Directory.systemTemp.createTempSync('tina_pipes_protocol_');
  addTearDown(() => ws.deleteSync(recursive: true));
  final provider = ScriptedProvider(script);
  final assembly = SessionAssembly.start(
    providerFactory: (_) => provider,
    options: AssemblyOptions(
      configPath: '/nonexistent/tina/config',
      workingDirectory: ws.path,
    ),
  );
  final input = StreamController<List<int>>();
  final events = <Map<String, dynamic>>[];
  final exitCode = runSessionPipes(
    assembly,
    input: input.stream,
    emit: (line) => events.add(jsonDecode(line) as Map<String, dynamic>),
    maxQueuedEvents: maxQueuedEvents ?? _SessionPipesProbe.maxQueuedEvents,
    maxQueuedCharacters:
        maxQueuedCharacters ?? _SessionPipesProbe.maxQueuedCharacters,
  );
  return (
    assembly: assembly,
    provider: provider,
    input: input,
    events: events,
    exitCode: exitCode,
  );
}

/// Test-only constants mirroring the production defaults without reaching
/// into the private server class.
abstract final class _SessionPipesProbe {
  static const maxQueuedEvents = 1024;
  static const maxQueuedCharacters = 8 << 20;
}

/// Waits until [predicate] matches an event, polling the captured list.
Future<Map<String, dynamic>> waitForEvent(
  List<Map<String, dynamic>> events,
  String what,
  bool Function(Map<String, dynamic>) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    for (final event in events) {
      if (predicate(event)) return event;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError(
      'timed out waiting for $what; events so far:\n${events.take(40)}');
}

Future<void> pump(StreamController<List<int>> input) =>
    Future<void>.delayed(Duration.zero);

void main() {
  test('a multi-byte character split across stdin chunks decodes whole', () async {
    // 'é' is two bytes, '—' three, '日' three; the write is split inside
    // each of them. The old per-chunk decoder threw a FormatException on
    // the first split character and the session died.
    const text = 'café — 日本語 reply';
    final (
      assembly: assembly,
      provider: provider,
      input: input,
      events: events,
      exitCode: exitCode,
    ) = _piped([scriptedReply('acknowledged: $text')]);
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    final line = jsonEncode({'op': 'submit', 'id': 'u1', 'line': text});
    final request = utf8.encode('$line\n');
    // One write per code point boundary: every multi-byte character is
    // split mid-sequence, exactly at a writer's chunk edge.
    final cuts = <int>[];
    var byteOffset = 0;
    for (final unit in line.runes) {
      final encoded = utf8.encode(String.fromCharCode(unit));
      byteOffset += encoded.length;
      if (encoded.length > 1) cuts.add(byteOffset - 1);
    }
    cuts.add(request.length - 1);
    var start = 0;
    for (final cut in cuts) {
      input.add(request.sublist(start, cut));
      await pump(input);
      start = cut;
    }
    input.add(request.sublist(start));

    final user = await waitForEvent(
      events,
      'the submitted text as a user message',
      (e) =>
          e['type'] == 'entry' &&
          e['entry']['type'] == 'message_appended' &&
          e['entry']['message']['role'] == 'user' &&
          (e['entry']['message']['content'] as List)
              .any((b) => b is Map && b['text'] == text),
    );
    expect(user['entry']['message']['content'], isA<List>());

    await waitForEvent(
      events,
      'assistant reply carrying the text',
      (e) =>
          e['type'] == 'entry' &&
          e['entry']['type'] == 'message_appended' &&
          e['entry']['message']['role'] == 'assistant' &&
          (e['entry']['message']['content'] as List)
              .any((b) => b is Map && (b['text'] as String?)!.contains(text)),
    );
    await waitForEvent(
      events,
      'u1 completed',
      (e) =>
          e['type'] == 'receipt' && e['id'] == 'u1' && e['state'] == 'completed',
    );

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(
      await exitCode.timeout(const Duration(seconds: 30)),
      0,
      reason: 'clean shutdown after the split-character turn',
    );
  });

  test('a bounded outbound queue drops under load and reports the overflow',
      () async {
    // A 10-character queue cannot hold two events, so the bound binds
    // deterministically: every queued event drops its predecessor, one
    // marker reports the count, and the session keeps serving input
    // afterwards. Whether the client saw any given queued event is not
    // the functional signal — queued events are exactly what drops — so
    // the immediate-write events (ready) and the engine-side provider
    // call count carry the liveness assertions.
    final (:assembly, :provider, :input, :events, :exitCode) = _piped(
      [scriptedReply('turn 0 done')],
      maxQueuedCharacters: 10,
    );
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    await waitForEvent(events, 'ready', (e) => e['type'] == 'ready');

    // The session still serves new input after the drops; the turn's
    // queued statuses and entries trip the bound.
    input.add(
        utf8.encode('${jsonEncode({'op': 'submit', 'id': 'c0', 'line': 'go'})}\n'));
    var deadline = DateTime.now().add(const Duration(seconds: 20));
    while (provider.callCount < 1 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(provider.callCount, 1, reason: 'the post-drop turn ran');

    final overflow = await waitForEvent(
      events,
      'the overflow marker',
      (e) => e['type'] == 'overflow',
    );
    expect(overflow['dropped'], greaterThan(0));
    expect(
      events
          .sublist(0, events.indexOf(overflow))
          .every((e) => e['type'] != 'overflow'),
      isTrue,
      reason: 'the first marker sits behind the surviving events',
    );

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(
      await exitCode.timeout(const Duration(seconds: 30)),
      0,
      reason: 'clean shutdown after overflow recovery',
    );
  });

  test('unbounded production defaults keep every event queued', () async {
    // At the production bounds a normal turn drops nothing: the full
    // event sequence for one turn survives intact.
    final (:assembly, :provider, :input, :events, :exitCode) =
        _piped([scriptedReply('only turn')]);
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    input.add(utf8.encode(
        '${jsonEncode({'op': 'submit', 'id': 's1', 'line': 'go'})}\n'));
    await waitForEvent(
      events,
      's1 completed',
      (e) =>
          e['type'] == 'receipt' && e['id'] == 's1' && e['state'] == 'completed',
    );
    await waitForEvent(
      events,
      'turn ended',
      (e) => e['type'] == 'entry' && e['entry']['type'] == 'turn_ended',
    );
    expect(
      events.any((e) => e['type'] == 'overflow'),
      isFalse,
      reason: 'no drops at production bounds for a normal turn',
    );

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(await exitCode.timeout(const Duration(seconds: 30)), 0);
  });

  test('discovery: commands ride ready, settings catalog, completion', () async {
    final (:assembly, :provider, :input, :events, :exitCode) =
        _piped([scriptedReply('done')]);
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    final ready = await waitForEvent(events, 'ready', (e) => e['type'] == 'ready');
    final commands = ready['commands'] as List;
    final mode = commands.firstWhere((c) => c['name'] == 'mode') as Map;
    expect(mode['description'], isA<String>());
    expect(mode['allowWhileRunning'], isA<bool>());

    input.add(utf8.encode('${jsonEncode({'op': 'commands'})}\n'));
    final echoed = await waitForEvent(
      events,
      'the commands event',
      (e) => e['type'] == 'commands',
    );
    expect(
      (echoed['commands'] as List).map((c) => c['name']),
      contains('mode'),
    );

    input.add(utf8.encode('${jsonEncode({'op': 'settings'})}\n'));
    final settings = await waitForEvent(
      events,
      'the settings event',
      (e) => e['type'] == 'settings',
    );
    expect(settings['model'], ready['model']);
    final catalog = settings['settings'] as List;
    expect(catalog, isNotEmpty, reason: 'the installed plugins define settings');
    for (final entry in catalog.cast<Map>()) {
      expect(entry['id'], isA<String>());
      expect(entry['label'], isA<String>());
      expect(entry['kind'], isA<String>());
      expect((entry['scopes'] as List), isNotEmpty);
    }

    input.add(utf8.encode(
        '${jsonEncode({'op': 'complete', 'name': 'mode', 'prefix': ''})}\n'));
    final suggestions = await waitForEvent(
      events,
      'the suggestions event',
      (e) => e['type'] == 'suggestions',
    );
    expect(suggestions['name'], 'mode');
    expect(suggestions['suggestions'], isA<List>());

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(await exitCode.timeout(const Duration(seconds: 30)), 0);
  });

  test('snapshot stream carries the front-end surface per update', () async {
    final (:assembly, :provider, :input, :events, :exitCode) =
        _piped([scriptedReply('done')]);
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    final ready = await waitForEvent(events, 'ready', (e) => e['type'] == 'ready');
    final first = await waitForEvent(
      events,
      'the first snapshot',
      (e) => e['type'] == 'snapshot',
    );
    expect(first['epoch'], ready['epoch']);
    expect(first['revision'], isA<int>());
    expect(first['features'], isA<Map>());
    expect(first['activeTools'], isA<Map>());
    expect(first['questions'], isA<List>());
    expect(first['plugins'], isA<List>());
    expect(first['pendingInputs'], isA<List>());
    for (final input in (first['pendingInputs'] as List)) {
      expect((input as Map)['line'], isA<String>());
      expect(input['id'], isA<String>());
    }
    expect(first['throughNoticeSeq'], isA<int>());

    input.add(utf8.encode(
        '${jsonEncode({'op': 'submit', 'id': 's1', 'line': 'go'})}\n'));
    await waitForEvent(
      events,
      's1 completed',
      (e) =>
          e['type'] == 'receipt' && e['id'] == 's1' && e['state'] == 'completed',
    );
    final last = events.lastWhere((e) => e['type'] == 'snapshot');
    expect(
      (last['revision'] as num).toInt(),
      greaterThan(first['revision'] as int),
      reason: 'the turn moved the snapshot revision',
    );

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(await exitCode.timeout(const Duration(seconds: 30)), 0);
  });

  test('history and notices pages catch a client up', () async {
    final (:assembly, :provider, :input, :events, :exitCode) =
        _piped([scriptedReply('done')]);
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    await waitForEvent(events, 'ready', (e) => e['type'] == 'ready');
    input.add(utf8.encode(
        '${jsonEncode({'op': 'submit', 'id': 'h1', 'line': 'go'})}\n'));
    await waitForEvent(
      events,
      'h1 completed',
      (e) =>
          e['type'] == 'receipt' && e['id'] == 'h1' && e['state'] == 'completed',
    );

    input.add(utf8.encode(
        '${jsonEncode({'op': 'history', 'afterSeq': -1, 'limit': 128})}\n'));
    final page = await waitForEvent(
      events,
      'the history page',
      (e) => e['type'] == 'history-page',
    );
    final entries = page['entries'] as List;
    expect(entries, isNotEmpty);
    expect(
      entries.map((e) => e['type']),
      containsAll(['turn_started', 'message_appended', 'turn_ended']),
    );
    for (final wire in entries.cast<Map>()) {
      final decoded = SessionEntry.fromJson(Map<String, dynamic>.from(wire));
      expect(decoded.seq, wire['seq'], reason: 'seq must survive the page');
    }

    input.add(utf8.encode(
        '${jsonEncode({'op': 'history', 'afterSeq': -1, 'limit': 2})}\n'));
    final bounded = await waitForEvent(
      events,
      'the bounded history page',
      (e) =>
          e['type'] == 'history-page' && (e['entries'] as List).length == 2,
    );
    expect(bounded['hasMore'], isTrue);

    input.add(utf8.encode(
        '${jsonEncode({'op': 'notices', 'afterSeq': -1, 'limit': 128})}\n'));
    final notices = await waitForEvent(
      events,
      'the notices page',
      (e) => e['type'] == 'notice-page',
    );
    expect(notices['entries'], isEmpty);
    expect(notices['hasMore'], isFalse,
        reason: 'a headless session wrote no notices');

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(await exitCode.timeout(const Duration(seconds: 30)), 0);
  });

  test('operations and questions ride the receipt protocol', () async {
    final (:assembly, :provider, :input, :events, :exitCode) =
        _piped([scriptedReply('done')]);
    addTearDown(() async {
      input.close();
      await exitCode;
      await assembly.shutdown();
    });

    await waitForEvent(events, 'ready', (e) => e['type'] == 'ready');

    input.add(utf8.encode('${jsonEncode({
      'op': 'operation',
      'plugin': 'tina/mode',
      'operation': 'set',
      'arguments': {'mode': 'allowEdits', 'expected_mode': 'ask'},
      'id': 'mode-1',
    })}\n'));
    await waitForEvent(
      events,
      'mode-1 completed',
      (e) =>
          e['type'] == 'receipt' &&
          e['id'] == 'mode-1' &&
          e['state'] == 'completed',
    );

    input.add(utf8.encode(
        '${jsonEncode({'op': 'answer', 'id': 'no-such-question', 'text': 'x'})}\n'));
    final answered = await waitForEvent(
      events,
      'the answer result',
      (e) => e['type'] == 'question-result',
    );
    expect(answered['id'], 'no-such-question');
    expect(answered['accepted'], isFalse,
        reason: 'no question is pending in this session');

    input.add(utf8.encode(
        '${jsonEncode({'op': 'dismiss', 'id': 'no-such-question'})}\n'));
    final dismissed = events.lastWhere(
      (e) => e['type'] == 'question-result',
      orElse: () => throw StateError('dismiss result missing'),
    );
    expect(dismissed['accepted'], isFalse);

    input.add(utf8.encode('${jsonEncode({'op': 'shutdown'})}\n'));
    expect(await exitCode.timeout(const Duration(seconds: 30)), 0);
  });
}
