import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina/conversation.dart';
import 'package:tina/session_commands/command_context.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Minimal [Agent] for command-handler tests — never actually runs a turn.
Agent _fakeAgent(LlmProvider provider, FakeHostInterface host) => Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: host,
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      system: '',
    );

/// A [CommandContext] fake that only implements the members `/model` reaches.
class _FakeCtx implements CommandContext {
  _FakeCtx({
    required this.conversation,
    this.openModelPicker,
    this.openImage,
    this.openBranch,
    this.openToolOutput,
    this.spendLedger,
  });

  /// The conversation [active] returns. Tests mutate its provider for assertions.
  final Conversation conversation;

  @override
  Conversation get active => conversation;

  // No summary sidecar service wired — `/index` takes the degraded ad-hoc
  // review fallback (returns CmdRun with the review prompt).
  @override
  SummaryIndex? get summaryIndex => null;

  @override
  Future<bool> Function(String prompt)? get confirm => null;

  @override
  Future<void> Function()? openModelPicker;

  @override
  Future<void> Function(String path)? openImage;

  @override
  Future<void> Function()? openBranch;

  @override
  Future<void> Function(int index)? openToolOutput;

  @override
  SpendLedger? spendLedger;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  // Unused by /model — throw on access.
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  SessionManager get sessionManager => throw UnimplementedError();

  @override
  SessionStore? get sessionStore => throw UnimplementedError();

  @override
  int get autoCompactThreshold => throw UnimplementedError();

  @override
  set autoCompactThreshold(int value) => throw UnimplementedError();

  @override
  int get autoCompactPreserveRecent => throw UnimplementedError();

  @override
  void Function()? get onSessionsChanged => throw UnimplementedError();

  @override
  Future<void> Function()? get openSettings => throw UnimplementedError();

  @override
  Future<void> Function()? get openPrompts => throw UnimplementedError();

  @override
  Future<void> newSession({String? providerId, String? model}) =>
      throw UnimplementedError();

  @override
  void switchSession(String id) => throw UnimplementedError();
}

Future<void> main() async {
  group('SessionCommandHandlers /image', () {
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

    test('bare /image with no path shows usage', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/image');
      expect(
        host.styledMessages.map((m) => m.message),
        contains('usage: /image <path>\n'),
      );
    });

    test('/image calls openImage with the path when available', () async {
      String? received;
      final handlers = SessionCommandHandlers(_FakeCtx(
        conversation: conv,
        openImage: (path) async => received = path,
      ));
      await handlers.dispatch('/image ./pics/cat.png');
      expect(received, './pics/cat.png');
    });

    test('/image with no openImage shows the headless warning', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/image foo.png');
      expect(
        host.styledMessages.map((m) => m.message),
        anyElement(contains('needs the interactive TUI')),
      );
    });
  });

  group('SessionCommandHandlers /model', () {
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

    _FakeCtx _ctx({Future<void> Function()? openModelPicker}) => _FakeCtx(
          conversation: conv,
          openModelPicker: openModelPicker,
        );

    test('bare /model calls openModelPicker when available', () async {
      var called = false;
      final ctx = _ctx(openModelPicker: () async {
        called = true;
      });
      final handlers = SessionCommandHandlers(ctx);

      await handlers.dispatch('/model');

      expect(called, isTrue);
    });

    test('/model with extra args shows usage and does not open picker',
        () async {
      var called = false;
      final ctx = _ctx(openModelPicker: () async {
        called = true;
      });
      final handlers = SessionCommandHandlers(ctx);

      await handlers.dispatch('/model extra arg');

      expect(called, isFalse);
      expect(
        host.styledMessages.map((m) => m.message),
        contains('usage: /model  (opens the picker)\n'),
      );
    });

    test('/model prints current model name when openModelPicker is null',
        () async {
      final ctx = _FakeCtx(conversation: conv); // openModelPicker defaults null
      final handlers = SessionCommandHandlers(ctx);

      await handlers.dispatch('/model');

      // Should print the current model from the provider
      expect(
        host.styledMessages.any(
          (m) => m.message.contains('test-model'),
        ),
        isTrue,
      );
    });
  });

  group('SessionCommandHandlers /branch', () {
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

    _FakeCtx _ctx({Future<void> Function()? openBranch}) => _FakeCtx(
          conversation: conv,
          openBranch: openBranch,
        );

    test('/branch is a recognized command (handled, not notCommand)',
        () async {
      final handlers = SessionCommandHandlers(_ctx());
      final result = await handlers.dispatch('/branch');
      expect(result, const CmdHandled());
    });

    test('/branch invokes the wired openBranch callback', () async {
      var called = false;
      final handlers = SessionCommandHandlers(_ctx(openBranch: () async {
        called = true;
      }));
      await handlers.dispatch('/branch');
      expect(called, isTrue);
    });

    test('/branch with no openBranch prints the headless warning', () async {
      final handlers = SessionCommandHandlers(_ctx()); // openBranch null
      await handlers.dispatch('/branch');
      expect(
        host.styledMessages.map((m) => m.message),
        anyElement(contains('needs the interactive TUI')),
      );
    });
  });

  group('SessionCommandHandlers /index', () {
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

    test('dispatches a CmdRun carrying the index prompt (not handled)', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      final result = await handlers.dispatch('/index');
      expect(result, isA<CmdRun>());
      final run = result as CmdRun;
      // The prompt instructs a review + ≤2 delegations via `delegate`.
      expect(run.prompt, contains('AT MOST 2'));
      expect(run.prompt.toLowerCase(), contains('delegate'));
      expect(run.prompt, contains('repository'));
    });

    test('is a recognized command (in allCommands)', () {
      expect(SessionCommandHandlers.allCommands, contains('/index'));
      expect(SessionCommandHandlers.allCommands, contains('/output'));
    });
  });

  group('SessionCommandHandlers /output', () {
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

    test('no argument opens the most recent capped output', () async {
      final opened = <int>[];
      final handlers = SessionCommandHandlers(
          _FakeCtx(conversation: conv, openToolOutput: (i) async => opened.add(i)));
      final res = await handlers.dispatch('/output');
      expect(res, isA<CmdHandled>());
      expect(opened, [0]);
    });

    test('/output n maps 1-based to the newest-first ring', () async {
      final opened = <int>[];
      final handlers = SessionCommandHandlers(
          _FakeCtx(conversation: conv, openToolOutput: (i) async => opened.add(i)));
      await handlers.dispatch('/output 3');
      expect(opened, [2]);
    });

    test('a non-numeric argument prints the usage hint', () async {
      final opened = <int>[];
      final handlers = SessionCommandHandlers(
          _FakeCtx(conversation: conv, openToolOutput: (i) async => opened.add(i)));
      await handlers.dispatch('/output xyz');
      expect(opened, isEmpty);
      expect(
        host.styledMessages.map((m) => m.message),
        anyElement(contains('usage: /output')),
      );
    });

    test('without a TUI wiring, prints the headless warning', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/output');
      expect(
        host.styledMessages.map((m) => m.message),
        anyElement(contains('needs the interactive TUI')),
      );
    });
  });

  group('SessionCommandHandlers /spend', () {
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

    test('prints the session total, the cap, and the throttle', () async {
      final ledger = SpendLedger(maxGlobalTokens: 50000000, requestsPerMinute: 30);
      ledger.record(const TokenUsage(inputTokens: 1000, outputTokens: 2000));
      final handlers = SessionCommandHandlers(
          _FakeCtx(conversation: conv, spendLedger: ledger));
      await handlers.dispatch('/spend');

      final joined = host.styledMessages.map((m) => m.message).join();
      expect(joined, contains('Session spend: 3,000 tokens'));
      expect(joined, contains('Global cap: 50,000,000'));
      expect(joined, contains('not tripped'));
      expect(joined, contains('Requests/min cap: 30'));
    });

    test('shows the tripped state and the restored portion', () async {
      final ledger = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      ledger.seed(500);
      ledger.record(const TokenUsage(inputTokens: 600, outputTokens: 0));
      final handlers = SessionCommandHandlers(
          _FakeCtx(conversation: conv, spendLedger: ledger));
      await handlers.dispatch('/spend');

      final joined = host.styledMessages.map((m) => m.message).join();
      expect(joined, contains('restored from a previous run'));
      expect(joined, contains('TRIPPED'));
    });

    test('without a ledger, warns', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/spend');
      expect(
        host.styledMessages.map((m) => m.message),
        anyElement(contains('no spend ledger')),
      );
    });
  });
}
