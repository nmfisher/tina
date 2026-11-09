// The pipes-backed SessionConnection, end to end: a real engine assembly
// runs `runSessionPipes` over injected byte streams while a
// `PipesConnection` serves the front-end contract on the other side — no
// subprocess, the exact shape Phase B's launcher wires to a spawned
// engine. Records: submit/receipt lifecycle, attachment snapshots and
// history paging, command and settings discovery, plugin operations.
//
// Run: dart test test/pipes_connection_test.dart
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:tina/session.dart';
import 'package:tina/src/pipes.dart';
import 'package:tina/src/pipes_connection.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

/// Polls [condition] until it holds; receipts cross the wire immediately,
/// but pushed entries land a few microtasks behind them.
Future<void> _waitFor(bool Function() condition,
    {String what = 'condition'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late SessionAssembly assembly;
  late ScriptedProvider provider;
  late StreamController<List<int>> toEngine;
  late StreamController<String> fromEngine;
  late PipesConnection connection;

  setUp(() async {
    final ws = Directory.systemTemp.createTempSync('tina_pipes_conn_');
    addTearDown(() => ws.deleteSync(recursive: true));
    provider = ScriptedProvider([scriptedReply('the engine answered')]);
    assembly = SessionAssembly.start(
      providerFactory: (_) => provider,
      options: AssemblyOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: ws.path,
      ),
    );
    toEngine = StreamController<List<int>>();
    fromEngine = StreamController<String>();
    final events = fromEngine.stream.map(
        (line) => jsonDecode(line) as Map<String, dynamic>);
    connection = PipesConnection(
      send: (line) => toEngine.add(utf8.encode('${jsonEncode(line)}\n')),
      events: events,
    );
    addTearDown(() async {
      toEngine.close();
      connection.close();
      await assembly.shutdown();
    });
    unawaited(runSessionPipes(assembly, input: toEngine.stream,
        emit: fromEngine.add));
    await connection.started.timeout(const Duration(seconds: 30));
  });

  test('submit through the interface completes with a result and receipts',
      () async {
    final request = connection.submitRequest('say something',
        id: connection.requestWindow.id('p-1'));
    final receipt = await request.completed.timeout(const Duration(seconds: 30));
    expect(receipt.state, SessionRequestState.completed);
    expect(receipt.result?.stopReason, StopReason.complete);
    expect(connection.status.running, isFalse);

    // The request stays addressable by ID, and a retry with the same ID
    // returns the same terminal receipt, as the protocol promises.
    expect(connection.request(connection.requestWindow.id('p-1')), same(request));
    final retry = connection.submitRequest('say something',
        id: connection.requestWindow.id('p-1'));
    expect(retry.completed, completion(receipt));
    final result = await connection.submit('and once through submit');
    expect(result.stopReason, StopReason.complete);
  });

  test('the attachment sees snapshots advance and history pages entries',
      () async {
    final attachment = connection.attach();
    var initial = attachment.initial;
    if (initial.plugins.isEmpty) {
      // attach() raced the engine's first snapshot event; the baseline is
      // the next update.
      final first = await attachment.next().timeout(const Duration(seconds: 30));
      initial = first!.snapshot;
    }
    expect(initial.throughSeq, greaterThanOrEqualTo(-1));
    expect(initial.plugins, isNotEmpty);
    expect(initial.cursor.epoch, isNotEmpty);

    await connection.submit('write the turn');
    SessionUpdate? update = await attachment.next()
        .timeout(const Duration(seconds: 30));
    while (update != null && update.snapshot.cursor.revision <= initial.cursor.revision) {
      update = await attachment.next().timeout(const Duration(seconds: 30));
    }
    expect(update, isNotNull);
    final settled = update!;
    // Receipts cross immediately; the turn's committed entries follow on
    // the same stream — wait until the cache pages the whole turn.
    await _waitFor(
        () => attachment
                .history(snapshot: settled.snapshot, afterSeq: -1, limit: 128)
                .entries
                .any((entry) => entry['type'] == 'turn_ended'),
        what: 'the committed turn in the history cache');
    final page = attachment.history(
        snapshot: settled.snapshot, afterSeq: -1, limit: 128);
    expect(page.entries, isNotEmpty);
    expect(
      page.entries.map((entry) => entry['type']),
      containsAll(['turn_started', 'message_appended', 'turn_ended']),
    );

    // The features surface rides the snapshot: the projection map is
    // present and typed, whatever the installed plugins project.
    expect(settled.snapshot.features, isA<Map<String, Object?>>());
    attachment.close();
  });

  test('discovery: commands, command routing and completion', () async {
    final mode = connection.commands
        .where((c) => c.name == 'mode')
        .toList();
    expect(mode, hasLength(1), reason: 'the mode command is discovered');

    // Routing resolves the discovered command exactly as the in-process
    // registry does, including the argument split.
    final call = connection.commandFor('/mode allowEdits');
    expect(call, isNotNull);
    expect(call!.command.name, 'mode');
    expect(call.argument, 'allowEdits');
    expect(connection.commandFor('/no-such-command'), isNull);
    expect(connection.commandFor('plain input'), isNull);

    final suggestions = await connection.completeCommand('mode', '');
    expect(suggestions, isA<List<String>>());
  });

  test('plugin operations ride receipts; the mode lands in the snapshot',
      () async {
    final operation = connection.submitOperation('tina/mode', 'set',
        arguments: {'mode': 'allowEdits', 'expected_mode': 'ask'},
        id: connection.requestWindow.id('mode-op-1'));
    final snapshot = await operation.completed.timeout(
        const Duration(seconds: 30));
    expect(snapshot.state, SessionRequestState.completed);
    expect(snapshot.workId, isNotNull);

    // The same surface a mode view consumes: the snapshot feature is not
    // projected by this assembly, but the operation's effect is visible
    // engine-side through a second operation failing on the expectation.
    // The stale expectation fails as an operation: a failed SessionResult
    // is a failed receipt with the error stop reason — the same terminal
    // receipt shape a TUI mode view consumes.
    final stale = connection.submitOperation('tina/mode', 'set',
        arguments: {'mode': 'allowEdits', 'expected_mode': 'ask'},
        id: connection.requestWindow.id('mode-op-2'));
    final staleSnapshot = await stale.completed
        .timeout(const Duration(seconds: 30));
    expect(staleSnapshot.state, SessionRequestState.failed);
    expect(staleSnapshot.result?.stopReason, StopReason.error,
        reason: 'the expected-mode guard reports the changed mode');

    // The mode change landed: the snapshot feature projection carries it.
    final update = await connection.attach().next()
        .timeout(const Duration(seconds: 30));
    expect(
        (update!.snapshot.features['tina/mode'] as Map)['mode'], 'allowEdits');
  });

  test('questions: answering without a pending question reports not accepted',
      () async {
    expect(connection.questions.canAnswer, isTrue);
    final accepted = connection.questions.answer('no-such-question', 'x');
    expect(accepted, isFalse);
  });

  test('cancellation of unknown work reports locally and stays harmless',
      () async {
    expect(connection.cancel(['no-such-work'], reason: 'record'),
        isFalse, reason: 'no cancellable work is live');
    // The engine replies with accepted:false; the session keeps serving.
    final result = await connection.submit('still here');
    expect(result.stopReason, StopReason.complete);
  });

  test('inputHistory reflects received entries; unsupported members throw',
      () async {
    await connection.submit('remember this');
    // The received entry stream carries the user message a few microtasks
    // behind the receipt that resolved the submit.
    await _waitFor(() => connection.inputHistory.contains('remember this'),
        what: 'the submitted text in inputHistory');
    expect(connection.inputHistory, contains('remember this'));

    expect(() => connection.output(connection.requestWindow.id('x')),
        throwsUnsupportedError);
    expect(() => connection.offerInput('x'), throwsUnsupportedError);
    expect(() => connection.offerCommand('/mode'), throwsUnsupportedError);
  });
}
