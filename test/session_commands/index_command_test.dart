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
import 'package:tina_engine/tina_engine.dart'
    show Agent, HostInterface, LlmProvider, PermissionPolicy,
        PermissionResponse, SpendLedger, TokenUsage, ToolRegistry;
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
  bool _proposalShown = false;

  @override
  Future<SummaryIndexStatus> status() async => _status;

  @override
  bool get proposalShown => _proposalShown;

  @override
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    List<String>? dirs,
    HostInterface? host,
    Future<void>? cancelSignal,
  }) async {
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
    this.spendLedger,
    this.runBackgroundIndex,
    this.runBackgroundEnvironment,
  });

  final Conversation conversation;

  @override
  Conversation get active => conversation;

  @override
  SummaryIndex? summaryIndex;

  @override
  Future<bool> Function(String prompt)? confirm;

  /// null by default (headless-style: run the fleet inline, cap not tripped).
  @override
  SpendLedger? spendLedger;

  /// null by default (headless: no background run). Tests that want the
  /// background path set this.
  @override
  Future<void> Function(Conversation conv, List<String>? dirs,
      {bool repartition})? runBackgroundIndex;

  /// null by default (headless: the environment agent never auto-runs).
  @override
  Future<void> Function(Conversation conv)? runBackgroundEnvironment;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

SummaryIndexStatus _status({
  required int total,
  required List<String> stale,
  bool firstRun = false,
  bool hasAllocations = false,
  List<String> deleted = const [],
  String sha = 'abcdef1234567890',
}) =>
    SummaryIndexStatus(
      totalDirs: total,
      staleDirs: stale,
      deletedDirs: deleted,
      headSha: sha,
      firstRun: firstRun,
      hasAllocations: hasAllocations,
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

  test('first run + confirm wired + no allocations: hands the main agent the '
      'layout proposal', () async {
    final idx = _StubIndex(
      _status(total: 4, stale: const ['lib', 'test'], firstRun: true),
      refreshResult: _result(4),
    );
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async => true,
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdRun>());
    final prompt = (res as CmdRun).prompt;
    expect(prompt, contains('repo_structure'));
    expect(prompt, contains('allocate_region'));
    expect(prompt, contains('run `/index` again'));
    expect(_notices().join(), contains('design the layout'));
    expect(idx.refreshCalls, 0);
  });

  test('first run + proposed layout: confirms before summarizing', () async {
    final idx = _StubIndex(
      _status(total: 3, stale: const ['lib', 'src', 'test'], firstRun: true,
          hasAllocations: true),
      refreshResult: _result(3, regeneratedDirs: const ['lib']),
    );
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async {
        expect(prompt, contains('proposed'));
        return true;
      },
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 1);
    expect(idx.lastRepartition, false);
    expect(_notices().join(), contains('Indexing 3'));
    expect(_notices().join(), contains('Indexed 3 director'));
  });

  test('first run + proposed layout declined: no refresh', () async {
    final idx = _StubIndex(
      _status(total: 3, stale: const ['lib'], firstRun: true,
          hasAllocations: true),
    );
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async => false,
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 0);
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

  test('first run + no allocations + proposal already shown: escape hatch',
      () async {
    // The proposal turn ran before but allocated nothing — /index must not
    // loop on another paid proposal turn. It offers the default-partition
    // fallback instead (finding D).
    final idx = _StubIndex(
      _status(total: 4, stale: const ['lib', 'test', 'packages', 'packages/c'],
          firstRun: true),
      refreshResult: _result(4),
    )
      .._proposalShown = true; // markProposalShown had run
    final confirmCalls = <String>[];
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async {
        confirmCalls.add(prompt);
        return true;
      },
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(confirmCalls.single, contains('allocated no regions'));
    expect(idx.refreshCalls, 1); // default partition indexed, not a proposal
  });

  test('first run + no allocations + proposal shown + decline: no refresh',
      () async {
    final idx = _StubIndex(
      _status(total: 4, stale: const ['lib', 'test', 'packages', 'packages/c'],
          firstRun: true),
      refreshResult: _result(4),
    )
      .._proposalShown = true;
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      confirm: (prompt) async => false,
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 0);
  });

  test('tripped spend cap skips /index (finding M)', () async {
    final idx = _StubIndex(
      _status(total: 4, stale: const ['lib', 'test', 'packages', 'packages/c'],
          firstRun: true),
      refreshResult: _result(4),
    );
    // Trip the ledger with a single oversized record (cap = 1 token).
    final ledger = SpendLedger(maxGlobalTokens: 1, requestsPerMinute: 0);
    ledger.record(TokenUsage(inputTokens: 100, outputTokens: 0));
    expect(ledger.tripped, isTrue);

    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      spendLedger: ledger,
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 0); // the fleet never launched
    expect(_notices().join(), contains('tripped'));
  });

  test('with runBackgroundIndex wired: returns immediately, delegates to it',
      () async {
    // In the TUI, /index hands the fleet to the background task and returns
    // at once — the task posts its own notices. The inline refresh +
    // _postIndexRefresh must NOT run (step 6).
    final idx = _StubIndex(
      _status(total: 4, stale: const ['lib', 'test', 'packages', 'packages/c'],
          firstRun: true),
      refreshResult: _result(4),
    );
    List<String>? capturedDirs;
    bool capturedRepartition = false;
    Conversation? capturedConv;
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      runBackgroundIndex: (c, dirs, {repartition = false}) async {
        capturedConv = c;
        capturedDirs = dirs;
        capturedRepartition = repartition;
      },
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(idx.refreshCalls, 0); // inline refresh NOT called
    expect(capturedConv, same(conv));
    expect(capturedDirs,
        ['lib', 'test', 'packages', 'packages/c']); // probed stale dirs
    expect(capturedRepartition, false);
    // No inline Indexed notice — the background task owns that.
    expect(_notices().join(), isNot(contains('Indexed')));
  });

  test('stale environment region: runs the background environment agent',
      () async {
    final idx = _StubIndex(
      SummaryIndexStatus(
        totalDirs: 2,
        staleDirs: const ['lib'],
        headSha: 'abcdef1234567890',
        firstRun: true,
        deletedDirs: const [],
        envFirstLoad: true,
      ),
      refreshResult: _result(2),
    );
    var envRuns = 0;
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      runBackgroundEnvironment: (c) async => envRuns++,
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(envRuns, 1);
    expect(_notices().join(),
        contains('running the environment agent in the background'));
  });

  test('stale environment region, headless: only reports, never runs', () async {
    final idx = _StubIndex(
      SummaryIndexStatus(
        totalDirs: 2,
        staleDirs: const ['lib'],
        headSha: 'abcdef1234567890',
        firstRun: true,
        deletedDirs: const [],
        envStaleReason: 'inputs changed since the last measurement',
      ),
      refreshResult: _result(2),
    );
    var envRuns = 0;
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      runBackgroundEnvironment: null, // headless wiring
    ));
    final res = await handlers.dispatch('/index');

    expect(res, isA<CmdHandled>());
    expect(envRuns, 0);
    expect(_notices().join(),
        contains('refresh it from an interactive session'));
  });

  test('current environment region: no environment notice', () async {
    final idx = _StubIndex(
      _status(total: 2, stale: const ['lib']),
      refreshResult: _result(1),
    );
    var envRuns = 0;
    final handlers = SessionCommandHandlers(_FakeCtx(
      conversation: conv,
      summaryIndex: idx,
      runBackgroundEnvironment: (c) async => envRuns++,
    ));
    await handlers.dispatch('/index');

    expect(envRuns, 0);
    expect(_notices().join(), isNot(contains('environment agent')));
  });
}
