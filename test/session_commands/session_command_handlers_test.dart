import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/tina_app.dart';

import 'package:tina/session_commands/session_command_handlers.dart';


import 'package:tina/tmux/tmux_support.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

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
    this.openSessionPicker,
    this.setPermissionMode,
    this.store,
    this.spendLedger,
    this.detachTmux,
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
  Future<void> Function(Conversation, IndexOptions)? get runClassification => null;

  @override
  Future<bool> Function(String prompt)? get confirm => null;

  @override
  Future<void> Function()? openModelPicker;

  @override
  Future<void> Function(String path)? openImage;

  @override
  Future<void> Function()? openBranch;

  @override
  Future<void> Function()? openSessionPicker;

  @override
  void Function(PermissionMode mode)? setPermissionMode;

  /// The on-disk store for the headless /sessions listing path.
  final SessionStore? store;

  @override
  SessionStore? get sessionStore => store;

  @override
  SpendLedger? spendLedger;

  /// The tmux detach seam (`/detach`); null in these tests unless set.
  @override
  Future<void> Function()? detachTmux;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  // Unused by /model — throw on access.
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  SessionManager get sessionManager => throw UnimplementedError();

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

  group('SessionCommandHandlers /sessions', () {
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

    test('/sessions opens the picker when the TUI wired one', () async {
      var opened = false;
      final handlers = SessionCommandHandlers(_FakeCtx(
        conversation: conv,
        openSessionPicker: () async => opened = true,
      ));
      await handlers.dispatch('/sessions');
      expect(opened, isTrue,
          reason: 'the TUI /sessions is the picker (same overlay as Alt+S), '
              'not a printed list');
    });

    test('headless (no picker): still lists the saved sessions', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      await store.append(
          sid, cid, Message(role: Role.user, content: [TextBlock('hi')]));
      final handlers = SessionCommandHandlers(
          _FakeCtx(conversation: conv, store: store));
      await handlers.dispatch('/sessions');
      expect(
        host.styledMessages.map((m) => m.message),
        anyElement(contains(sid)),
        reason: 'headless keeps the list — the ids are needed for --resume',
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

  group('SessionCommandHandlers /permissions <mode>', () {
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

    test('no arg prints the rules incl. the current mode', () async {
      conv.policy.mode = PermissionMode.readAll;
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/permissions');
      final joined = host.styledMessages.map((m) => m.message).join();
      expect(joined, contains('mode: readAll'));
      expect(joined, contains('defaults:'));
    });

    test('a valid mode invokes the wired switcher', () async {
      final switched = <PermissionMode>[];
      final handlers = SessionCommandHandlers(_FakeCtx(
        conversation: conv,
        setPermissionMode: switched.add,
      ));
      await handlers.dispatch('/permissions allow-edits');
      expect(switched, [PermissionMode.allowEdits]);
      expect(host.styledMessages.map((m) => m.message).join(),
          contains('permission mode: allow-edits'));
    });

    test('no arg lists remembered approvals with scope and who answered',
        () async {
      conv.policy.remember('bash', 'git status', PermissionDecision.allow);
      conv.policy.remember('fetch', 'https://example.com/x',
          PermissionDecision.allow,
          source: GrantSource.classifier);
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/permissions');
      final joined = host.styledMessages.map((m) => m.message).join();
      expect(joined, contains('remembered approvals'));
      expect(joined, contains('bash:git status'));
      expect(joined, contains('this conversation, until tina exits'));
      expect(joined, contains('you'),
          reason: 'a grant you gave says so');
      expect(joined, contains('classifier'),
          reason: 'a grant the model made is not mistaken for yours');
    });

    test('revoke takes back one answer without touching the others', () async {
      conv.policy.remember('bash', 'git status', PermissionDecision.allow);
      conv.policy.remember('bash', 'ls -la', PermissionDecision.allow);
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/permissions revoke bash:git status');

      expect(host.styledMessages.map((m) => m.message).join(),
          contains('revoked 1 remembered approval'));
      expect(conv.policy.sessionGrants.single.rule.pattern, 'ls -la');
    });

    test('revoke all clears the conversation', () async {
      conv.policy.remember('bash', 'git status', PermissionDecision.allow);
      conv.policy.remember('write', '/tmp/*', PermissionDecision.allow);
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/permissions revoke all');
      expect(conv.policy.sessionGrants, isEmpty);
      expect(host.styledMessages.map((m) => m.message).join(),
          contains('revoked 2 remembered approvals'));
    });

    test('revoking something that was never remembered says so', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/permissions revoke bash');
      expect(host.styledMessages.map((m) => m.message).join(),
          contains('nothing remembered'));
    });

    test('unknown mode errors without switching', () async {
      var switched = false;
      final handlers = SessionCommandHandlers(_FakeCtx(
        conversation: conv,
        setPermissionMode: (_) => switched = true,
      ));
      await handlers.dispatch('/permissions fast');
      expect(switched, isFalse);
      expect(
        host.styledMessages.map((m) => m.message).join(),
        contains('unknown mode'),
      );
    });

    test('headless (no switcher wired) reports the flag instead', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/permissions auto');
      expect(
        host.styledMessages.map((m) => m.message).join(),
        contains('--permission-mode auto'),
      );
    });
  });

  group('SessionCommandHandlers /save', () {
    late FakeHostInterface host;
    late FakeProvider provider;
    late Conversation conv;
    late Directory dir;

    setUp(() async {
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
      dir = await Directory.systemTemp.createTemp('tina_save_test');
      addTearDown(() => dir.delete(recursive: true));
    });

    /// A conversation with a live recorder over [store], session `s1`.
    Conversation recorded(Conversation c, SessionStore store) => Conversation(
          id: c.id,
          label: c.label,
          agent: c.agent,
          provider: c.provider,
          host: c.host,
          policy: c.policy,
          recorder:
              SessionRecorder(store, 's1', 'c-live', providerId: 'anthropic'),
        );

    test(
        'writes a markdown transcript of every conversation and prints the '
        'absolute path', () async {
      final store = MemorySessionStore();
      await store.createSession(providerId: 'anthropic', sessionId: 's1');
      final cA = await store.createConversationWithMeta(
          's1', const ConversationMetaInput(label: 'main'));
      await store.append(
          's1', cA, Message(role: Role.user, content: [TextBlock('hello')]));
      await store.append('s1', cA,
          Message(role: Role.assistant, content: [TextBlock('world')]));
      final cB = await store.createConversationWithMeta(
          's1',
          const ConversationMetaInput(
              label: 'helper', kind: ConversationKind.subAgent));
      await store.append(
          's1', cB, Message(role: Role.user, content: [TextBlock('sub job')]));

      final handlers =
          SessionCommandHandlers(_FakeCtx(conversation: recorded(conv, store)));
      final target = p.join(dir.path, 'out.md');
      final res = await handlers.dispatch('/save $target');

      expect(res, isA<CmdHandled>());
      final file = File(target);
      expect(file.existsSync(), isTrue);
      final text = file.readAsStringSync();
      expect(text, startsWith('# Session transcript — s1\n'));
      expect(text, contains('> hello\n'), reason: 'title from first user msg');
      expect(text, contains('## main — primary\n'));
      expect(text, contains('## helper — subAgent\n'));
      expect(text, contains('### user\n\nhello\n'));
      expect(text, contains('- conversations: 2, messages: 3\n'));
      final joined = host.styledMessages.map((m) => m.message).join();
      expect(joined, contains('saved 3 messages across 2 conversations'));
      expect(joined, contains(target), reason: 'absolute target is echoed');
    });

    test('a relative path resolves against the cwd and still writes', () async {
      final store = MemorySessionStore();
      await store.createSession(providerId: 'anthropic', sessionId: 's1');
      final cid = await store.createConversation('s1');
      await store.append(
          's1', cid, Message(role: Role.user, content: [TextBlock('rel')]));
      final handlers =
          SessionCommandHandlers(_FakeCtx(conversation: recorded(conv, store)));
      final name = 'tina_save_rel_${DateTime.now().microsecondsSinceEpoch}.md';
      await handlers.dispatch('/save $name');
      final expected = File(p.join(Directory.current.path, name));
      expect(expected.existsSync(), isTrue,
          reason: 'relative paths land in the process cwd');
      expect(host.styledMessages.map((m) => m.message).join(),
          contains(expected.path));
      expected.deleteSync();
    });

    test('no argument prints usage', () async {
      final handlers =
          SessionCommandHandlers(_FakeCtx(conversation: recorded(conv, MemorySessionStore())));
      await handlers.dispatch('/save');
      expect(
        host.styledMessages.map((m) => m.message).join(),
        contains('usage: /save <path>'),
      );
    });

    test('extra arguments print usage too', () async {
      final handlers =
          SessionCommandHandlers(_FakeCtx(conversation: recorded(conv, MemorySessionStore())));
      await handlers.dispatch('/save a b');
      expect(
        host.styledMessages.map((m) => m.message).join(),
        contains('usage: /save <path>'),
      );
    });

    test('without persistence reports there is nothing to save', () async {
      // No recorder on the conversation, no ctx.sessionStore.
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/save ${p.join(dir.path, 'x.md')}');
      expect(
        host.styledMessages.map((m) => m.message).join(),
        contains('session persistence is disabled'),
      );
      expect(host.styledMessages.map((m) => m.style),
          contains(HostMessageStyle.error));
    });

    test('missing parent directory errors without creating it', () async {
      final store = MemorySessionStore();
      await store.createSession(providerId: 'anthropic', sessionId: 's1');
      await store.createConversation('s1');
      final handlers =
          SessionCommandHandlers(_FakeCtx(conversation: recorded(conv, store)));
      final target = p.join(dir.path, 'nope', 'out.md');
      await handlers.dispatch('/save $target');
      expect(Directory(p.join(dir.path, 'nope')).existsSync(), isFalse,
          reason: '/save must not mkdir');
      expect(File(target).existsSync(), isFalse);
      expect(host.styledMessages.map((m) => m.message).join(),
          contains('directory does not exist'));
    });

    test('an existing file is never overwritten', () async {
      final store = MemorySessionStore();
      await store.createSession(providerId: 'anthropic', sessionId: 's1');
      await store.createConversation('s1');
      final handlers =
          SessionCommandHandlers(_FakeCtx(conversation: recorded(conv, store)));
      final target = p.join(dir.path, 'existing.md');
      File(target).writeAsStringSync('keep me');
      await handlers.dispatch('/save $target');
      expect(File(target).readAsStringSync(), 'keep me');
      expect(host.styledMessages.map((m) => m.message).join(),
          contains('refusing to overwrite'));
    });

    test('/help lists /save', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/help');
      expect(host.messages.join(), contains('/save <path>'));
    });

    test('unknown commands still error after adding /save', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      final res = await handlers.dispatch('/savee nope');
      expect(res, isA<CmdHandled>());
      expect(host.styledMessages.map((m) => m.message).join(),
          contains('unknown command'));
    });
  });

  group('SessionCommandHandlers /detach (tin-f5xt)', () {
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

    test('wired seam is called and the coordinator owns the messaging',
        () async {
      var seamCalls = 0;
      final handlers = SessionCommandHandlers(_FakeCtx(
        conversation: conv,
        detachTmux: () async => seamCalls++,
      ));
      final res = await handlers.dispatch('/detach');
      expect(seamCalls, 1,
          reason: 'the command delegates to the coordinator-owned closure');
      expect(res, isA<CmdHandled>());
      // The hint is the HEADLESS path's job — with the seam wired the handler
      // itself prints nothing about tmux.
      expect(
          host.styledMessages
              .map((m) => m.message)
              .where((m) => m.contains('tmux')),
          isEmpty,
          reason: 'the wired closure owns every user-facing line');
    });

    test('headless (null seam) prints exactly the one-line hint', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      final res = await handlers.dispatch('/detach');
      expect(res, isA<CmdHandled>());
      final tmuxLines = host.styledMessages
          .map((m) => m.message)
          .where((m) => m.contains('tmux'))
          .toList();
      expect(tmuxLines, hasLength(1), reason: 'one line, not a paragraph');
      expect(tmuxLines.single, '${TmuxSupport.notInTmuxHint}\n',
          reason: 'the exact hint string, with its newline');
      expect(
        host.styledMessages
            .firstWhere((m) => m.message == '${TmuxSupport.notInTmuxHint}\n')
            .style,
        HostMessageStyle.dim,
        reason: 'dim — it is a nudge, not an error',
      );
    });

    test('/help lists /detach with the Alt+D keybind', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      await handlers.dispatch('/help');
      final help = host.messages.join();
      expect(help, contains('/detach'));
      expect(help, contains('Alt+D'));
    });

    test('/detach is a known command, not an unknown-command error', () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      final res = await handlers.dispatch('/detach');
      expect(res, isA<CmdHandled>());
      expect(host.styledMessages.map((m) => m.message).join(),
          isNot(contains('unknown command')));
    });
  });
  group('the /explore command', () {
    test(
      '/explore dispatches a normal turn with a restricted registry',
      () async {
        final host = FakeHostInterface();
        addTearDown(host.dispose);
        final provider = FakeProvider.always(model: 'm');
        final tools = ToolRegistry([ExploreProjectTool(open: () => null)]);
        final agent = Agent(
          provider: provider,
          tools: tools,
          sink: host,
          policy: PermissionPolicy(),
          asker: (_) async => PermissionResponse.denyOnce,
          system: '',
        );
        final conversation = Conversation(
          id: 'c',
          label: 'c',
          agent: agent,
          provider: provider,
          host: host,
          policy: PermissionPolicy(),
        );
        final handler = SessionCommandHandlers(Context(conversation));
        final result = await handler.dispatch(
          '/explore where is authentication?',
        );
        expect(result, isA<CmdRun>());
        final prompt = (result as CmdRun).prompt;
        expect(prompt, contains('where is authentication?'));
        final scoped = explorationToolsForTurn(tools, prompt)!;
        expect(scoped['explore_project'], same(tools['explore_project']));
        expect(scoped.executionBlock('read', {}), isNotNull);
        expect(scoped.executionBlock('delegate', {}), isNotNull);
        expect(explorationToolsForTurn(tools, 'normal turn'), isNull);
        expect(await handler.dispatch('/explore'), isA<CmdHandled>());
        expect(host.messages.join(), contains('Usage: /explore'));
      },
    );
  });
}

class Context implements CommandContext {
  @override
  final Conversation active;
  Context(this.active);
  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
