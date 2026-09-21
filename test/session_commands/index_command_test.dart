import 'dart:async';
import 'package:tina_app/tina_app.dart';

import 'package:tina/session_commands/session_command_handlers.dart';

import 'package:tina_engine/tina_engine.dart'
    show
        Agent,
        LlmProvider,
        PermissionPolicy,
        PermissionResponse,
        SpendLedger,
        TokenUsage,
        ToolRegistry;
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

class _FakeCtx implements CommandContext {
  _FakeCtx({
    required this.conversation,
    this.confirm,
    this.spendLedger,
    this.runBackgroundIndex,
    this.runClassification,
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
  Future<void> Function(
    Conversation conv,
    List<String>? dirs, {
    bool repartition,
  })?
  runBackgroundIndex;

  /// Optional classifier command capability.
  @override
  Future<void> Function(Conversation conv, IndexOptions options)?
  runClassification;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

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

  for (final mode in ['', 'status', 'refresh', 'view']) {
    test('index $mode invokes only classification', () async {
      final calls = <String>[];
      final handlers = SessionCommandHandlers(
        _FakeCtx(
          conversation: conv,
          confirm: (_) async =>
              throw StateError('Index must not prompt for a summary layout'),
          runBackgroundIndex: (_, _, {bool repartition = false}) async =>
              throw StateError('Index must not launch summaries'),
          runClassification: (conversation, mode) async {
            expect(conversation, same(conv));
            expect(mode.method, LanguageMethod.extensions);
            calls.add(mode.mode);
          },
        ),
      );
      expect(await handlers.dispatch('/index $mode'.trim()), isA<CmdHandled>());
      expect(calls, [mode]);
      await handlers.dispatch('/index invalid');
      await handlers.dispatch('/index status extra');
      expect(calls, [mode]);
      expect(host.messages.join(), contains('Usage: /index'));
    });
  }

  test(
    'missing classifier reports unavailable without a fallback agent turn',
    () async {
      final handlers = SessionCommandHandlers(_FakeCtx(conversation: conv));
      expect(await handlers.dispatch('/index'), isA<CmdHandled>());
      expect(host.messages.join(), contains('Project index unavailable'));
    },
  );

  test('spend cap blocks JEV classification but allows its status', () async {
    final calls = <String>[];
    final ledger = SpendLedger(maxGlobalTokens: 1, requestsPerMinute: 0);
    ledger.record(TokenUsage(inputTokens: 100, outputTokens: 0));
    final handlers = SessionCommandHandlers(
      _FakeCtx(
        conversation: conv,
        spendLedger: ledger,
        runClassification: (_, mode) async {
          calls.add(mode.mode);
        },
      ),
    );
    expect(await handlers.dispatch('/index jev'), isA<CmdHandled>());
    expect(await handlers.dispatch('/index jev refresh'), isA<CmdHandled>());
    expect(calls, isEmpty);
    expect(await handlers.dispatch('/index jev status'), isA<CmdHandled>());
    expect(await handlers.dispatch('/index jev view'), isA<CmdHandled>());
    expect(calls, ['status', 'view']);
  });

  test(
    'extension indexing remains available after the model spend cap is reached',
    () async {
      final calls = <IndexOptions>[];
      final ledger = SpendLedger(maxGlobalTokens: 1, requestsPerMinute: 0);
      ledger.record(TokenUsage(inputTokens: 100, outputTokens: 0));
      final handlers = SessionCommandHandlers(
        _FakeCtx(
          conversation: conv,
          spendLedger: ledger,
          runClassification: (_, options) async => calls.add(options),
        ),
      );
      await handlers.dispatch('/index extensions');
      await handlers.dispatch('/index extensions refresh');
      await handlers.dispatch('/index status extensions');
      expect(
        calls.map((c) => c.method),
        everyElement(LanguageMethod.extensions),
      );
      expect(calls.map((c) => c.mode), ['', 'refresh', 'status']);
      await handlers.dispatch('/index extensions jev');
      await handlers.dispatch('/index refresh status');
      expect(calls, hasLength(3));
      expect(host.messages.join(), contains(IndexOptions.usage));
    },
  );
}
