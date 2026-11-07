import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine_2/tina_engine_2.dart';

/// Stage-1 scripted client: drives headless native tina over plain pipes.
///
/// Spawns the engine as a subprocess (`--pipes`), writes line-delimited
/// JSON requests to its stdin and reads line-delimited JSON events from its
/// stdout, then proves the stage-1 exit test against the container's real
/// model route (the provider configured in `~/.tina/config`):
///
///   1. one real agent turn — provider responds, a tool call runs, a file
///      edit lands on disk;
///   2. a mid-turn cancellation sent over the pipe — the engine observes
///      it, stops the turn and stays consistent;
///   3. a second turn after the cancel still completes.
///
/// Every committed entry that crosses the pipe is round-tripped through the
/// engine's own `SessionEntry` serializer as the serialization check.
///
/// Usage (from the repository root, credentials in the environment only —
/// the probe never reads or writes them, it only forwards the environment
/// it was given):
///
///     dart apps/tina_cli/tool/pipes_probe.dart [--workspace DIR]
///         [--timeout-secs 300]
///
/// Exits 0 when every phase passed, 1 otherwise. Prints the raw event
/// transcript as it goes.
Future<void> main(List<String> args) async {
  var workspace = '${Directory.systemTemp.path}/tina-pipes-probe';
  var timeout = const Duration(seconds: 300);
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--workspace':
        workspace = args[++i];
      case '--timeout-secs':
        timeout = Duration(seconds: int.parse(args[++i]));
      case '--help' || '-h':
        stdout.writeln(
          'usage: dart tool/pipes_probe.dart '
          '[--workspace DIR] [--timeout-secs N]',
        );
        return;
      default:
        stderr.writeln('unknown argument: ${args[i]} (see --help)');
        exitCode = 2;
        return;
    }
  }

  var cliPackage = File(p.fromUri(Platform.script)).parent.parent;
  while (!File(p.join(cliPackage.path, 'bin', 'tina.dart')).existsSync()) {
    if (cliPackage.parent.path == cliPackage.path) {
      stderr.writeln('cannot locate the tina CLI package');
      exitCode = 1;
      return;
    }
    cliPackage = cliPackage.parent;
  }

  Directory(workspace).createSync(recursive: true);
  final target = File(p.join(workspace, 'stage1.txt'));
  if (target.existsSync()) target.deleteSync();

  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/tina.dart',
      '--cwd',
      workspace,
      '--no-sandbox',
      '--yolo',
      '--pipes',
    ],
    workingDirectory: cliPackage.path,
    // The provider credential rides the inherited environment, exactly as
    // the config expects; nothing is written to any file.
    environment: Platform.environment,
  );

  stdout.writeln(
    '[probe] engine pid=${process.pid} workspace=$workspace '
    'model route: default config',
  );

  final probe = _Probe(process, timeout);
  var passed = false;
  try {
    passed = await probe.run(target);
  } finally {
    if (!passed) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.catchError((Object _) => -1);
    }
  }
  exitCode = passed ? 0 : 1;
}

final class _Probe {
  _Probe(this.process, this.timeout);

  final Process process;
  final Duration timeout;
  final events = <Map<String, dynamic>>[];
  final waiters =
      <bool Function(Map<String, dynamic>), Completer<Map<String, dynamic>>>{};
  final failures = <String>[];
  late final StreamSubscription<String> _pump;

  Future<bool> run(File target) async {
    _pump = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: (Object error) {
            failures.add('stdout error: $error');
          },
        );
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    try {
      await _phase('ready', _ready);
      await _phase(
        'turn 1: provider + tool call + file edit',
        () => _turn1(target),
      );
      await _phase('turn 2: cancel mid-turn', _turn2);
      await _phase('turn 3: works after the cancel', _turn3);
      await _phase('shutdown', _shutdown);
      await process.exitCode.timeout(timeout);
      return failures.isEmpty;
    } on TimeoutException catch (error) {
      failures.add('timeout: $error');
      return false;
    } catch (error) {
      failures.add('$error');
      return false;
    } finally {
      await _pump.cancel();
      if (failures.isNotEmpty) {
        stderr.writeln('\n[probe] FAILURES (${failures.length}):');
        for (final failure in failures) {
          stderr.writeln('[probe] - $failure');
        }
      }
    }
  }

  Future<void> _phase(String name, Future<void> Function() body) async {
    stdout.writeln('\n[probe] === $name ===');
    try {
      await body().timeout(timeout);
      stdout.writeln('[probe] --- $name: OK');
    } on TimeoutException {
      failures.add('$name timed out after $timeout');
      rethrow;
    }
  }

  void _onLine(String line) {
    stdout.writeln('[engine] $line');
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      failures.add('engine emitted a non-JSON line: $line');
      return;
    }
    events.add(event);
    for (final entry in waiters.entries.toList()) {
      if (entry.key(event) && !entry.value.isCompleted) {
        entry.value.complete(event);
      }
    }
  }

  void _send(Map<String, dynamic> request) {
    process.stdin.writeln(jsonEncode(request));
  }

  Future<Map<String, dynamic>> _waitFor(
    String what,
    bool Function(Map<String, dynamic>) predicate, {
    Duration? timeout,
  }) {
    final seen = events.where(predicate).firstOrNull;
    if (seen != null) return Future.value(seen);
    final completer = Completer<Map<String, dynamic>>();
    waiters[predicate] = completer;
    return completer.future.timeout(
      timeout ?? this.timeout,
      onTimeout: () {
        throw TimeoutException(
          'waiting for $what; ${events.length} events so far; '
          'last: ${events.isEmpty ? "none" : events.last}',
        );
      },
    );
  }

  Future<Map<String, dynamic>> _receipt(String id, String state) => _waitFor(
    'receipt $id -> $state',
    (e) => e['type'] == 'receipt' && e['id'] == id && e['state'] == state,
  );

  Future<void> _ready() async {
    final ready = await _waitFor('ready', (e) => e['type'] == 'ready');
    stdout.writeln(
      '[probe] session=${ready['session']} model=${ready['model']}',
    );
  }

  Future<void> _turn1(File target) async {
    _send({
      'op': 'submit',
      'id': 'c1',
      'line':
          'Create a file named stage1.txt in the current directory '
          'with exactly this content (and nothing else): stage-1 pipe edit\n'
          'Use your file tools to write it, then reply with just: DONE',
    });
    final running = await _receipt('c1', 'running');
    stdout.writeln('[probe] turn 1 work=${running['workId']}');
    final toolUse = await _waitFor(
      'a write tool call',
      (e) =>
          e['type'] == 'entry' &&
          e['entry']['type'] == 'message_appended' &&
          _toolUse(e['entry']['message']) != null,
    );
    final call = _toolUse(toolUse['entry']['message'])!;
    stdout.writeln('[probe] tool call: ${call['name']} ${call['input']}');
    final result = await _waitFor(
      'the tool result',
      (e) =>
          e['type'] == 'entry' &&
          e['entry']['type'] == 'message_appended' &&
          _toolResult(e['entry']['message'], call['id'] as String) != null,
    );
    final block = _toolResult(
      result['entry']['message'],
      call['id'] as String,
    )!;
    if (block['is_error'] == true) {
      failures.add('the file tool failed: ${block['content']}');
    }
    await _receipt('c1', 'completed');
    await _turnEnded('complete');
    if (!target.existsSync()) {
      failures.add('file edit did not land on disk: ${target.path}');
    } else {
      final written = target.readAsStringSync();
      stdout.writeln('[probe] file on disk: ${jsonEncode(written)}');
      if (written.trim() != 'stage-1 pipe edit') {
        failures.add('file content mismatch: ${jsonEncode(written)}');
      }
    }
    _checkRoundTrip();
  }

  Future<void> _turn2() async {
    _send({
      'op': 'submit',
      'id': 'c2',
      'line':
          'Count from 1 to 1000, one number per line, nothing else. '
          'Do not stop early.',
    });
    final running = await _receipt('c2', 'running');
    final work = running['workId'] as String;
    stdout.writeln('[probe] turn 2 work=$work; letting it stream...');
    // Give the provider call time to be genuinely mid-turn, then cancel
    // over the pipe.
    await Future<void>.delayed(const Duration(seconds: 8));
    _send({'op': 'cancel', 'work': work, 'reason': 'stage-1 probe cancel'});
    final cancelEvent = await _waitFor(
      'the cancel acknowledgement',
      (e) => e['type'] == 'cancel' && e['work'] == work,
    );
    if (cancelEvent['accepted'] != true) {
      failures.add('engine refused the cancellation: $cancelEvent');
    }
    await _receipt('c2', 'cancelled');
    await _turnEnded('cancelled');
    final idle = await _waitFor(
      'idle status after the cancel',
      (e) => e['type'] == 'status' && e['running'] == false && !e['busy'],
    );
    stdout.writeln(
      '[probe] engine idle after cancel '
      '(pending=${idle['pendingInputCount']}, closed=${idle['closed']})',
    );
    _checkRoundTrip();
  }

  Future<void> _turn3() async {
    _send({
      'op': 'submit',
      'id': 'c3',
      'line': 'Reply with exactly the word PONG and nothing else.',
    });
    await _receipt('c3', 'completed');
    final reply = await _waitFor(
      'the final assistant text',
      (e) =>
          e['type'] == 'entry' &&
          e['entry']['type'] == 'message_appended' &&
          e['entry']['message']['role'] == 'assistant' &&
          _textContent(e['entry']['message']).contains('PONG'),
    );
    stdout.writeln(
      '[probe] post-cancel reply: ${jsonEncode(_textContent(reply['entry']['message']))}',
    );
    await _turnEnded('complete');
    _checkRoundTrip();
  }

  Future<void> _shutdown() async {
    _send({'op': 'shutdown'});
    await _waitFor('bye', (e) => e['type'] == 'bye');
    final code = await process.exitCode.timeout(timeout);
    stdout.writeln('[probe] engine exit code: $code');
    if (code != 0) failures.add('engine exit code $code, expected 0');
  }

  Future<void> _turnEnded(String reason) => _waitFor(
    'turn_ended ($reason)',
    (e) =>
        e['type'] == 'entry' &&
        e['entry']['type'] == 'turn_ended' &&
        e['entry']['reason'] == reason,
  );

  /// The serialization check: every committed entry must survive the pipe.
  /// Known convention: `toJson` omits a zero `seq` and `fromJson` reads the
  /// missing key as zero — semantically lossless; the envelope carries seq.
  void _checkRoundTrip() {
    for (final event in events) {
      if (event['type'] != 'entry') continue;
      final wire = Map<String, dynamic>.from(event['entry'] as Map);
      wire.remove('features');
      wire.remove('unavailable_features');
      final SessionEntry decoded;
      try {
        decoded = SessionEntry.fromJson(Map<String, dynamic>.from(wire));
      } catch (error) {
        failures.add('entry does not decode: $wire ($error)');
        continue;
      }
      if (decoded.seq != wire['seq']) {
        failures.add('seq did not survive the pipe: $wire');
      }
      final expected = Map<String, dynamic>.of(wire);
      if (decoded.seq == 0) expected.remove('seq');
      final reencoded = decoded.toJson();
      if (!_deepEqual(reencoded, expected)) {
        failures.add('entry did not round-trip: $wire -> $reencoded');
      }
    }
  }
}

/// Deep JSON equality (Dart maps compare by identity, not content).
bool _deepEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    return a.entries.every(
      (e) => b.containsKey(e.key) && _deepEqual(e.value, b[e.key]),
    );
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

Map<String, dynamic>? _toolUse(Map message) {
  for (final block in message['content'] as List) {
    if (block is Map && block['type'] == 'tool_use') {
      return Map<String, dynamic>.from(block);
    }
  }
  return null;
}

Map<String, dynamic>? _toolResult(Map message, String toolUseId) {
  for (final block in message['content'] as List) {
    if (block is Map &&
        block['type'] == 'tool_result' &&
        block['tool_use_id'] == toolUseId) {
      return Map<String, dynamic>.from(block);
    }
  }
  return null;
}

String _textContent(Map message) => [
  for (final block in message['content'] as List)
    if (block is Map && block['type'] == 'text') block['text'] as String,
].join();
