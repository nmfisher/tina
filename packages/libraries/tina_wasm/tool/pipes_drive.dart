#!/usr/bin/env dart
/// The stage-5 exit-test driver: one full agent turn over the pipes
/// protocol, against whichever engine a command names.
///
///   dart run tool/pipes_drive.dart -- <engine command...>
///
/// Spawns the engine command (the native `dart run bin/tina.dart --pipes`
/// or the wasm engine under `test_runner`), waits for `ready`, submits
/// one prompt, and records every event until the turn completes: the
/// provider's tool call, the `write` tool's execution, the final answer.
/// Then it verifies the file landed in the workspace and shuts the
/// engine down. The recorded transcript goes to stdout, so native and
/// wasm runs can be compared after normalizing the session/epoch ids.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final separator = args.indexOf('--');
  if (separator < 0 || separator + 1 >= args.length) {
    stderr.writeln(
        'usage: pipes_drive.dart [--workspace DIR] -- <engine command...>');
    exitCode = 2;
    return;
  }
  final command = args.skip(separator + 1).toList();
  if (command.isEmpty) {
    stderr.writeln('no engine command given');
    exitCode = 2;
    return;
  }

  // The engine's workspace: where the native engine runs (its cwd) and
  // where a wasm run's preopen '.' points. Defaults to a fresh temp dir.
  var workspaceArg = args.contains('--workspace')
      ? args[args.indexOf('--workspace') + 1]
      : null;
  final workspace = workspaceArg == null
      ? Directory.systemTemp.createTempSync('stage5-drive')
      : (Directory(workspaceArg)..createSync(recursive: true));
  workspaceArg ??= workspace.path;
  final target = File('${workspace.path}/stage5.txt');
  if (target.existsSync()) target.deleteSync();

  final process = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: workspace.path,
    environment: Platform.environment,
  );
  stdout.writeln('[drive] engine: ${command.join(' ')}');
  stdout.writeln('[drive] workspace: ${workspace.path}');

  var ready = Completer<Map<String, dynamic>>();
  var completed = Completer<void>();
  var toolRan = false;
  var sawToolCall = false;
  final failures = <String>[];

  void line(String raw) {
    stdout.writeln('[engine] $raw');
    Map<String, dynamic> event;
    try {
      event = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      failures.add('non-JSON engine line: $raw');
      return;
    }
    switch (event['type']) {
      case 'ready':
        if (!ready.isCompleted) ready.complete(event);
      case 'entry':
        final entry = event['entry'] as Map<String, dynamic>?;
        final payload = entry?['message'];
        if (payload is Map && payload['content'] is List) {
          for (final block in payload['content'] as List) {
            if (block is Map) {
              if (block['type'] == 'tool_use') sawToolCall = true;
              if (block['type'] == 'tool_result') toolRan = true;
            }
          }
        }
      case 'receipt':
        if (event['state'] == 'completed' && !completed.isCompleted) {
          completed.complete();
        }
        if (event['state'] == 'failed' && !completed.isCompleted) {
          failures.add('request failed: ${event['detail']}');
          completed.complete();
        }
      case 'error':
        failures.add('engine error: ${event['error']}');
    }
  }

  final pump = process.stdout
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(line, onDone: () {});
  final errPump = process.stderr
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((raw) => stdout.writeln('[engine-err] $raw'));

  try {
    final readyEvent = await ready.future.timeout(const Duration(seconds: 300));
    stdout.writeln('[drive] ready: session=${readyEvent['session']}');
    process.stdin.writeln(jsonEncode({
      'op': 'submit',
      'id': 'turn-1',
      'line': 'Create stage5.txt with the content the tools give you.',
    }));
    // Spawned engines can pay a large startup/JIT delay; the turn's
    // window matches the stage-1 probe's.
    await completed.future.timeout(const Duration(seconds: 300));
    await pump.cancel();
    await errPump.cancel();
    process.stdin.writeln(jsonEncode({'op': 'shutdown'}));
    await process.exitCode.timeout(const Duration(seconds: 60));
  } catch (error) {
    failures.add('driver: $error');
    process.kill();
    await process.exitCode.catchError((Object _) => -1);
  }

  final wrote = target.existsSync() ? target.readAsStringSync() : null;
  stdout.writeln('[drive] file written: ${wrote != null}');
  if (wrote != null) {
    stdout.writeln('[drive] file content: ${wrote.trim()}');
  }
  stdout.writeln('[drive] saw tool call: $sawToolCall');
  stdout.writeln('[drive] tool completed: $toolRan');
  final ok = failures.isEmpty &&
      sawToolCall &&
      toolRan &&
      wrote != null &&
      wrote.contains('stage5 edit landed');
  stdout.writeln('[drive] RESULT: ${ok ? 'PASS' : 'FAIL'}');
  for (final failure in failures) {
    stdout.writeln('[drive] failure: $failure');
  }
  exitCode = ok ? 0 : 1;
}
