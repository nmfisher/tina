#!/usr/bin/env dart
/// The stage-6 front-end client: a thin `HostInterface` client that
/// drives an engine over the `--pipes` protocol — the native TUI cannot
/// be pointed at an out-of-process engine (the daemon proposal is
/// unimplemented), so this is the front end that connects, drives,
/// renders and records.
///
///   # scripted scenario against an engine command:
///   dart run tool/front_end.dart --workspace WS --scenario S.json \
///     --record out.transcript -- <engine command...>
///
///   # interactive: JSON ops on this client's stdin, rendered events out
///   dart run tool/front_end.dart --workspace WS -- <engine command...>
///
/// The client speaks exactly the engine's protocol (submit / cancel /
/// approve / status / shutdown) — no client-side command language. A
/// scenario file sequences the same ops with waits and expectations;
/// `--record` captures the raw event transcript, `--normalized` the
/// native-vs-wasm comparable form.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final separator = args.indexOf('--');
  if (separator < 0 || separator + 1 >= args.length) {
    stderr.writeln('usage: front_end.dart [--workspace DIR] '
        '[--scenario FILE] [--record FILE] [--render] -- <engine...>');
    exitCode = 2;
    return;
  }
  final command = args.skip(separator + 1).toList();
  String? arg(String name) => args.contains(name)
      ? args[args.indexOf(name) + 1]
      : null;

  final workspaceArg = arg('--workspace');
  final workspace = workspaceArg == null
      ? Directory.systemTemp.createTempSync('stage6-front')
      : (Directory(workspaceArg)..createSync(recursive: true));

  final scenarioFile = arg('--scenario');
  final record = arg('--record');
  final render = args.contains('--render') || scenarioFile == null;
  Scenario? scenario;
  if (scenarioFile != null) {
    scenario = Scenario.load(scenarioFile);
  }

  final process = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: workspace.path,
    environment: Platform.environment,
  );
  final client = _FrontEndClient(
    process,
    workspace: workspace.path,
    render: render,
    record: record,
  );
  final ok = await client.run(scenario);
  exitCode = ok ? 0 : 1;
}

/// One scripted engine interaction: the same ops a client sends, with
/// waits and expectations between them.
final class Scenario {
  Scenario(this.name, this.moves);
  final String name;
  final List<Map<String, dynamic>> moves;

  static Scenario load(String path) {
    final decoded =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    return Scenario(
      decoded['name'] as String? ?? path,
      (decoded['moves'] as List).cast<Map<String, dynamic>>(),
    );
  }
}

final class _FrontEndClient {
  _FrontEndClient(this.process,
      {required this.workspace, required this.render, this.record});

  final Process process;
  final String workspace;
  final bool render;
  final String? record;

  final _events = <Map<String, dynamic>>[];
  final _waiters = <_Wait>[];
  final _renderSink = StringBuffer();
  IOSink? _recordSink;
  final _failures = <String>[];
  bool _done = false;

  /// Values captured from waited-for events, for send templating: the
  /// approval id of the last approval a scenario waited on is
  /// `$approval`, the last turn's work id `$work`.
  final _bindings = <String, String>{};

  Future<bool> run(Scenario? scenario) async {
    _recordSink =
        record == null ? null : File(record!).openWrite(mode: FileMode.write);
    final exited = Completer<int>();
    final pump = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () {});
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _say('[engine-err] $line');
    });
    unawaited(process.exitCode.then((code) {
      if (!exited.isCompleted) exited.complete(code);
    }));

    try {
      if (scenario == null) {
        await _interactive();
      } else {
        await _play(scenario);
        process.stdin.writeln(jsonEncode({'op': 'shutdown'}));
      }
      final code = await exited.future.timeout(const Duration(seconds: 60));
      if (code != 0) _failures.add('engine exited $code');
    } catch (error) {
      _failures.add('client: $error');
      process.kill();
      await process.exitCode.catchError((Object _) => -1);
    } finally {
      await pump.cancel();
      await _recordSink?.flush();
      await _recordSink?.close();
    }
    stdout.write(_renderSink.toString());
    final ok = _failures.isEmpty;
    _say('[front] RESULT: ${ok ? 'PASS' : 'FAIL'}');
    for (final failure in _failures) {
      _say('[front] failure: $failure');
    }
    return ok;
  }

  // ---- event flow --------------------------------------------------------

  void _onLine(String raw) {
    _say('[engine] $raw');
    Map<String, dynamic>? event;
    try {
      event = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _failures.add('non-JSON engine line: $raw');
      return;
    }
    _events.add(event);
    _recordSink?.writeln(raw);
    switch (event['type']) {
      case 'ready':
        _say('[front] ready session=${event['session']}');
      case 'approval':
        _say('[front] approval asked: ${event['operation']} '
            '${event['target']} — ${event['reason']}');
      case 'approval-result':
        _say('[front] approval ${event['decision']} '
            '${event['accepted'] == true ? 'accepted' : 'REJECTED'}');
      case 'receipt' when event['state'] == 'completed':
        _say('[front] turn ${event['id']} completed: ${event['detail']}');
      case 'receipt' when event['state'] == 'failed':
        _say('[front] turn ${event['id']} FAILED: ${event['detail']}');
      case 'entry':
        _renderEntry(event);
      case 'error':
        _say('[front] engine error: ${event['error']}');
      case 'bye':
        _done = true;
    }
    final waiters = List.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (matchesPattern(event, waiter.pattern)) {
        waiter.event = event;
        if (!waiter.done.isCompleted) waiter.done.complete();
      } else {
        _waiters.add(waiter);
      }
    }
  }

  void _renderEntry(Map<String, dynamic> event) {
    final entry = event['entry'] as Map<String, dynamic>?;
    if (entry == null) return;
    switch (entry['type']) {
      case 'input_recorded':
        _say('[front] user: ${entry['text']}');
      case 'message_appended':
        final message = entry['message'] as Map<String, dynamic>?;
        final content = message?['content'];
        if (content is List) {
          for (final block in content) {
            if (block is! Map) continue;
            switch (block['type']) {
              case 'text':
                _say('[front] ${message!['role']}: ${block['text']}');
              case 'tool_use':
                _say('[front] tool call ${block['name']}('
                    '${jsonEncode(block['input'])})');
              case 'tool_result':
                _say('[front] tool result: '
                    '${(block['content'] as String?)?.trim()}');
            }
          }
        }
    }
  }

  void _say(String line) {
    if (render) _renderSink.writeln(line);
  }

  // ---- driving -----------------------------------------------------------

  Future<void> _interactive() async {
    // Interactive mode: this client's stdin is the driver's. Lines are
    // protocol ops, passed through verbatim; EOF shuts the engine down.
    final lines = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (_done) break;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      process.stdin.writeln(trimmed);
      if (jsonDecode(trimmed) case {'op': 'shutdown'}) {
        break;
      }
    }
    if (!_done) process.stdin.writeln(jsonEncode({'op': 'shutdown'}));
    await process.exitCode.timeout(const Duration(seconds: 60));
  }

  Future<void> _play(Scenario scenario) async {
    _say('[front] scenario: ${scenario.name}');
    await _waitFor(
      {'type': 'ready'},
      const Duration(seconds: 300),
      'engine ready',
    );
    for (final move in scenario.moves) {
      if (_done) break;
      if (move case {'send': final Map<String, dynamic> op}) {
        final expanded = _expand(op);
        process.stdin.writeln(jsonEncode(expanded));
        _say('[front] sent: ${jsonEncode(expanded)}');
      } else if (move case {'wait': final Map<String, dynamic> pattern}) {
        final timeout = pattern['timeout'] is int
            ? Duration(seconds: pattern['timeout'] as int)
            : const Duration(seconds: 300);
        await _waitFor(
          pattern..remove('timeout'),
          timeout,
          jsonEncode(pattern),
        );
      } else if (move case {'expect': final Map<String, dynamic> check}) {
        _check(check);
      } else {
        _failures.add('unknown scenario move: ${jsonEncode(move)}');
      }
    }
  }

  /// Substitute `$approval` / `$work` bindings into a send op: the ids a
  /// scenario cannot know ahead of time.
  Map<String, dynamic> _expand(Map<String, dynamic> op) => {
        for (final entry in op.entries)
          entry.key: switch (entry.value) {
            '\$approval' => _bindings['approval'],
            '\$work' => _bindings['work'],
            String value => value,
            _ => entry.value,
          },
      };

  Future<void> _waitFor(Map<String, dynamic> pattern, Duration timeout,
      String description) async {
    // Already-seen events can satisfy a wait (a fast engine may beat the
    // scenario to it); otherwise subscribe for the next match.
    Map<String, dynamic>? matched;
    for (final event in _events) {
      if (matchesPattern(event, pattern)) {
        matched = event;
        break;
      }
    }
    matched ??= await _subscribe(pattern, timeout, description);
    if (matched != null) {
      _bind(matched);
      _say('[front] wait satisfied: $description');
    }
  }

  Future<Map<String, dynamic>?> _subscribe(
      Map<String, dynamic> pattern, Duration timeout, String description) async {
    final waiter = _Wait(pattern, description);
    _waiters.add(waiter);
    try {
      await waiter.done.future.timeout(timeout);
      return waiter.event;
    } on TimeoutException {
      _failures.add('timed out waiting for $description');
      return null;
    }
  }

  /// Capture ids later sends need: the approval id, the active work id.
  void _bind(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'approval':
        _bindings['approval'] = event['id'] as String;
      case 'status':
        final work = event['work'];
        if (work is List && work.isNotEmpty && work.first is Map) {
          _bindings['work'] = (work.first as Map)['id'] as String? ?? '';
        }
      case 'receipt':
        final work = event['workId'];
        if (work is String && work.isNotEmpty) _bindings['work'] = work;
    }
  }

  void _check(Map<String, dynamic> check) {
    if (check case {'file': final String path}) {
      final file = File('$workspace/${_relative(path)}');
      if (!file.existsSync()) {
        _failures.add('expected file $path missing');
        return;
      }
      final content = file.readAsStringSync();
      if (check case {'contains': final String needle}) {
        if (!content.contains(needle)) {
          _failures.add('file $path lacks "$needle": ${content.trim()}');
        }
      }
      if (check case {'equals': final String expected}) {
        if (content.trim() != expected.trim()) {
          _failures.add('file $path is "${content.trim()}"');
        }
      }
      _say('[front] file ok: $path');
    } else if (check case {'event': final Map<String, dynamic> pattern}) {
      final match =
          _events.any((event) => matchesPattern(event, pattern));
      if (match) {
        _say('[front] event ok: ${jsonEncode(pattern)}');
      } else {
        _failures.add('no event matches ${jsonEncode(pattern)}');
      }
    } else if (check case {'no-event': final Map<String, dynamic> pattern}) {
      final match =
          _events.any((event) => matchesPattern(event, pattern));
      if (match) {
        _failures.add('unexpected event matched ${jsonEncode(pattern)}');
      } else {
        _say('[front] no-event ok: ${jsonEncode(pattern)}');
      }
    } else if (check case {'file-absent': final String path}) {
      if (File('$workspace/${_relative(path)}').existsSync()) {
        _failures.add('file $path should not exist');
      } else {
        _say('[front] file-absent ok: $path');
      }
    } else {
      _failures.add('unknown expectation: ${jsonEncode(check)}');
    }
  }

  /// Native engines see absolute workspace paths; the wasm engine sees
  /// guest-relative ones. Expectations use the relative form.
  String _relative(String path) =>
      path.startsWith('$workspace/') ? path.substring(workspace.length + 1) : path;
}

final class _Wait {
  _Wait(this.pattern, this.description);
  final Map<String, dynamic> pattern;
  final String description;
  final done = Completer<void>();
  Map<String, dynamic>? event;
}

/// Subset match: every pattern key must be present with an equal value
/// (nested maps recurse; dotted keys reach into nested maps).
bool matchesPattern(Map<String, dynamic> event, Map<String, dynamic> pattern) {
  for (final entry in pattern.entries) {
    final want = entry.value;
    final have = valueAt(event, entry.key);
    if (want is Map<String, dynamic>) {
      if (have is! Map<String, dynamic> || !matchesPattern(have, want)) {
        return false;
      }
    } else if (want is List) {
      if (have is! List || want.length != have.length) return false;
      for (var i = 0; i < want.length; i++) {
        final w = want[i];
        final h = have[i];
        if (w is Map<String, dynamic>) {
          if (h is! Map<String, dynamic> || !matchesPattern(h, w)) {
            return false;
          }
        } else if (w != h) {
          return false;
        }
      }
    } else if ('$have' != '$want') {
      return false;
    }
  }
  return true;
}

Object? valueAt(Map<String, dynamic> event, String key) {
  // 'entry.message.role' reaches into nested maps.
  Object? current = event;
  for (final part in key.split('.')) {
    if (current is Map<String, dynamic>) {
      current = current[part];
    } else {
      return null;
    }
  }
  return current;
}
