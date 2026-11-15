// The pipes approval surface, end to end: a real engine assembly in ask
// mode runs `runSessionPipes` over injected streams; a `PipesConnection`
// sees `approval` events as pending asks and answers one through the
// `approve` op. The same contract the Phase B launcher wires to a spawned
// engine, recorded without a subprocess.
//
// Run: dart test test/pipes_connection_approvals_test.dart
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
import 'package:tina_approvals/tina_approvals.dart'
    show ApprovalDecision, ApprovalKind, ApprovalRequest;
import 'package:tina_host/tina_host.dart';

/// Polls [condition] until it holds; approval events land a few microtasks
/// behind the ask that raised them.
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
  late Directory workspace;
  late ScriptedProvider provider;
  late StreamController<List<int>> toEngine;
  late StreamController<String> fromEngine;
  late PipesConnection connection;
  late File outsideTarget;
  final approvalResults = <Map<String, dynamic>>[];

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('tina_pipes_approvals_');
    outsideTarget = File(
        '${workspace.parent.path}/tina_pipes_approvals_${DateTime.now().microsecondsSinceEpoch}.txt');
    addTearDown(() async {
      if (outsideTarget.existsSync()) outsideTarget.deleteSync();
      workspace.deleteSync(recursive: true);
    });
    provider = ScriptedProvider([
      scriptedReply('writing the file', calls: [
        ToolUseBlock(id: 'toolu_approvals', name: 'write', input: {
          'filePath': outsideTarget.path,
          'content': 'approved write\n',
        }),
      ]),
      scriptedReply('the write is done'),
    ]);
    final assembly = SessionAssembly.start(
      providerFactory: (_) => provider,
      options: AssemblyOptions(
        configPath: '/nonexistent/tina/config',
        workingDirectory: workspace.path,
        // The same selection the headless CLI makes: the stream channel is
        // the one the wire answers on, in ask mode.
        approvalChannel: 'tina/approvals-stream',
        plugins: ['tina/tools', 'tina/mode'],
      ),
    );
    toEngine = StreamController<List<int>>();
    fromEngine = StreamController<String>();
    final events = fromEngine.stream
        .map((line) => jsonDecode(line) as Map<String, dynamic>);
    connection = PipesConnection(
      send: (line) => toEngine.add(utf8.encode('${jsonEncode(line)}\n')),
      events: events.map((event) {
        if (event['type'] == 'approval-result') approvalResults.add(event);
        return event;
      }),
    );
    addTearDown(() async {
      toEngine.close();
      connection.close();
      await assembly.shutdown();
    });
    unawaited(runSessionPipes(assembly,
        input: toEngine.stream, emit: fromEngine.add));
    await connection.started.timeout(const Duration(seconds: 30));
  });

  test('an ask-mode write surfaces as an approval ask and answers over the wire',
      () async {
    final seen = <List<ApprovalRequest>>[];
    // ignore: unused_local_variable
    final release = connection.approvals.listen(seen.add);

    final request = connection.submitRequest('write the file',
        id: connection.requestWindow.id('p-1'));
    await _waitFor(() => connection.approvals.pending.isNotEmpty,
        what: 'pending approval');
    final pending = connection.approvals.pending.single;
    expect(pending.operation, isNotEmpty);
    expect(pending.kind, ApprovalKind.permission);

    // The ask's answer crosses the `approve` op; the tool runs and the
    // turn completes.
    expect(connection.approvals.respond(pending.id, ApprovalDecision.allow),
        isTrue);
    final receipt = await request.completed.timeout(const Duration(seconds: 30));
    expect(receipt.state, SessionRequestState.completed);
    await _waitFor(() => approvalResults.isNotEmpty,
        what: 'approval-result event');
    expect(approvalResults.single['accepted'], isTrue);
    expect(approvalResults.single['decision'], 'allow');
    expect(outsideTarget.readAsStringSync(), contains('approved write'));
    expect(connection.approvals.pending, isEmpty);
    expect(seen, isNotEmpty);
  });

  test('an unknown or answered ask cannot be answered twice', () async {
    final request = connection.submitRequest('write the file',
        id: connection.requestWindow.id('p-2'));
    await _waitFor(() => connection.approvals.pending.isNotEmpty,
        what: 'pending approval');
    final id = connection.approvals.pending.single.id;
    expect(connection.approvals.respond(id, ApprovalDecision.deny), isTrue);
    expect(connection.approvals.respond(id, ApprovalDecision.allow), isFalse);
    await _waitFor(() => connection.approvals.pending.isEmpty,
        what: 'pending cleared');
    expect(
        approvalResults
            .where((result) => result['id'] == id)
            .every((result) => result['decision'] == 'deny'),
        isTrue);
    await request.completed.timeout(const Duration(seconds: 30));
  });
}

