// Branch coverage for the `/index` staleness dance in
// [SessionCommandHandlers._handleIndex]. A stub [SummaryIndex] (overriding
// [SummaryIndex.status] + [SummaryIndex.refresh]) drives the three branches —
// first-run/all-stale, partly stale, up-to-date — plus the confirm y/n and the
// degraded fallback, without any LLM or real git.

import 'dart:async';

import 'package:tina/conversation.dart';
import 'package:tina/session_commands/command_context.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

Agent _fakeAgent(LlmProvider provider, FakeHostInterface host) => Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: host,
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      system: '',
    );

/// A [SummaryIndex] whose probe + fleet run are stubbed, so the dance can be
/// driven without a composition or LLM. Captures refresh calls + repartition.
class _StubIndex extends SummaryIndex {
  _StubIndex(this._status, {this.refreshResult})
      : super(projectRoot: '/nonexistent-in-test');
  SummaryIndexStatus _status;
  SummaryIndexResult? refreshResult;
  int refreshCalls = 0;
  bool? lastRepartition;

  @override
  Future<SummaryIndexStatus> status() async => _status;

  @override
  Future<SummaryIndexResult> refresh({bool repartition = false}) async {
    refreshCalls++;
    lastRepartition = repartition;
    return refreshResult!;
  }
}

/// A [CommandContext] fake exposing only what `/index` reaches: [active],
/// [commandHooks], [summaryIndex], [confirm]. The rest throw.
class _FakeCtx implements CommandContext {
  _FakeCtx({
    required this.conversation,
    this.summaryIndex,
    this.confirm,
  });

  final Conversation conversation;

  @override
  Conversation get active => conversation;

  @override
  SummaryIndex? summaryIndex;

  @override
  Future<bool> Function(String prompt)? confirm;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

SummaryIndexStatus _status({
  required int total,
  required List<String> stale,
  bool firstRun = false,
  List<String> deleted = const [],
  String sha = 'abcdef1234567890',
}) =>
    SummaryIndexStatus(
      totalDirs: total,
      staleDirs: stale,
      deletedDirs: deleted,
      headSha: sha,
      firstRun: firstRun,
    );

SummaryIndexResult _result(int regenerated,
        {List<String> regeneratedDirs = const [], String sha = 'zzz9998877'}) =>
    SummaryIndexResult(
      status: _status(total: 3, stale: const [], sha: sha),
      regenerated: regenerated,
      regeneratedDirs: regeneratedDirs,
      deletedDirs: const [],
    );

void main() {
  late FakeHostInterface host;
  late FakeProvider provider;
  late Conversation conv;

  setUp(() {
    host = FakeHostInterface();
    provider = FakeProvider.always(model: 'test-model');
    conv = Conversation(
      id: 'test-conv',
      label: 'test-model',
      agent: _fakeAgent(provider, host),
      provider: provider,
      host: host,
      policy: PermissionPolicy(),
    );
  });

  // The notices the host recorded (the command's user-facing output).
  List<String> _notices() => host.messages;

  test('first run: indexes all, posts Indexing + Indexed', () async {
    final idx = _StubIndex(
      _status(total: 4, stale: const ['lib', 'test', 'packages', 'packages/c'],
          firstRun: true),
      refreshResult: _result(4, regeneratedDirs: const ['lib', 'test']),
    );
    final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv, summaryIndex: idx));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 1);
    expect(idx.lastRepartition, false);
    expect(_notices().join(), contains('Indexing 4'));
    expect(_notices().join(), contains('Indexed 4 director'));
    // The post-refresh sha is shortened to 7 chars.
    expect(_notices().join(), contains('zzz9998'));
  });

  test('partly stale: reports the stale dirs and refreshes them', () async {
    final idx = _StubIndex(
      _status(total: 3, stale: const ['lib']),
      refreshResult: _result(1, regeneratedDirs: const ['lib']),
    );
    final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv, summaryIndex: idx));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 1);
    expect(idx.lastRepartition, false);
    expect(_notices().join(), contains('1/3 dirs stale: lib'));
    expect(_notices().join(), contains('Refreshing'));
    expect(_notices().join(), contains('Refreshed 1 director'));
  });

  test('up to date + confirm yes: re-indexes all with repartition', () async {
    final idx = _StubIndex(
      _status(total: 3, stale: const []),
      refreshResult: _result(3, regeneratedDirs: const ['lib', 'test', 'x']),
    );
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async {
        expect(prompt, contains('Re-run all 3'));
        return true;
      },
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(_notices().join(), contains('up to date'));
    expect(idx.refreshCalls, 1);
    expect(idx.lastRepartition, true);
    expect(_notices().join(), contains('Re-indexing 3'));
  });

  test('up to date + confirm no: does not refresh', () async {
    final idx = _StubIndex(_status(total: 3, stale: const []));
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async => false,
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(_notices().join(), contains('up to date'));
    expect(idx.refreshCalls, 0);
  });

  test('up to date + no confirm (headless): reports and stops, no refresh',
      () async {
    final idx = _StubIndex(_status(total: 3, stale: const []));
    final handlers =
        SessionCommandHandlers(_FakeCtx(conversation: conv, summaryIndex: idx));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(_notices().join(), contains('up to date'));
    expect(idx.refreshCalls, 0);
  });

  test('no summaryIndex: degrades to the ad-hoc in-chat review prompt',
      () async {
    final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdRun>());
    expect((res as CmdRun).prompt, contains('Review the structure of this repository'));
    expect(_notices().join(), contains('sidecar unavailable'));
  });
}
