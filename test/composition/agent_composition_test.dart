import 'dart:io';
import 'dart:convert';
import 'package:tina_app/tina_app.dart';

import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';

import 'package:tina/config.dart';


import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Pins the composition wiring: `createScheduler` over the default pipeline,
/// and `buildAgent`'s interactive/headless split. Both modes share the full
/// file/shell tool set; interactive layers on delegate + channels + image
/// rendering, and the workflow surface (`launch_workflow` + `stop_workflow`)
/// is added in either mode when a [WorkflowSupervisor] is wired.
void main() {
  Config testConfig() => Config.parse(const ['--backend', 'ansi']);

  // A run seam that never actually runs a workflow — the tool-set tests don't
  // invoke it; they only assert it lands in the registry.
  RunWorkflow noopRun({Outcome outcome = const Outcome.success()}) =>
      ({required workflowName, required sink, required conversationId, input,
          history, cancelSignal, onEvent}) async =>
          PipelineRunResult(outcome: outcome, runDir: '');

  // A supervisor over the noop run; wired into buildAgent below.
  WorkflowSupervisor noopSupervisor() => WorkflowSupervisor(run: noopRun());

  group('buildAgent main tool set', () {
    test('interactive main gets full file tools + delegate + channels', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final agent = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config, // withSubAgents defaults true
      );
      // Full file/shell tool set is now present in interactive mode too.
      for (final t in ['read', 'write', 'edit', 'bash', 'search', 'grep', 'glob']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      // Plus the orchestration surface.
      for (final t in ['delegate', 'send', 'receive', 'close', 'render_image']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      // No supervisor wired → no workflow surface.
      expect(agent.tools['launch_workflow'], isNull);
      expect(agent.tools['stop_workflow'], isNull);
    });

    test('main policy follows live mode while the environment catalog stays stable', () async {
      final config = testConfig();
      final scheduler = createScheduler(config: config,
          registry: ProviderRegistry(env: {}), pipeline: defaultPipeline);
      addTearDown(scheduler.dispose);
      final policy = config.buildPolicy();
      final driver = buildAgent(pipeline: defaultPipeline, scheduler: scheduler,
          conversationId: 'main', provider: FakeProvider(const []),
          host: FakeHostInterface(), policy: policy, config: config);
      String schemas(ToolRegistry tools) => jsonEncode([
        for (final t in tools.schemas)
          {'name': t.name, 'description': t.description, 'input_schema': t.inputSchema},
      ]);
      final before = schemas(driver.tools);
      policy.mode = PermissionMode.readAll;
      expect(policy.check('bash', {}), PermissionDecision.deny);
      expect(schemas(EnvironmentToolStage(driver.tools)), before);
      policy.mode = PermissionMode.ask;
      expect(policy.check('bash', {}), PermissionDecision.ask);
      expect(schemas(driver.tools), before);
    });

    test('headless main gets the full base set, no delegate/channels', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final driver = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        withSubAgents: false,
      );
      for (final t in ['read', 'write', 'edit', 'bash', 'search', 'grep', 'glob']) {
        expect(driver.tools[t], isNotNull, reason: t);
      }
      expect(driver.tools['delegate'], isNull);
      expect(driver.tools['send'], isNull);
    });

    test('transportRetryAttempts is opt-in: default 0, flag value passes '
        'through (#28)', () {
      // The shared default: no caller passes anything → engine default 0,
      // pre-#28 abort-on-first-mid-stream-error behavior (TUI included —
      // bin/tina.dart is the only caller that forwards the config value).
      final scheduler = createScheduler(
        config: testConfig(),
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      Agent build(Config c, {int? attempts}) =>
          ((attempts == null
                  ? buildAgent(
                      // Omitting the parameter entirely: the composition must
                      // not silently opt anyone in.
                      pipeline: defaultPipeline,
                      scheduler: scheduler,
                      conversationId: 'c1',
                      provider: FakeProvider(const [], model: 'm'),
                      host: FakeHostInterface(),
                      policy: c.buildPolicy(),
                      config: c,
                      withSubAgents: false,
                    )
                  : buildAgent(
                      pipeline: defaultPipeline,
                      scheduler: scheduler,
                      conversationId: 'c1',
                      provider: FakeProvider(const [], model: 'm'),
                      host: FakeHostInterface(),
                      policy: c.buildPolicy(),
                      config: c,
                      withSubAgents: false,
                      transportRetryAttempts: attempts,
                    )) as AgentDriverAdapter)
              .agent;
      expect(build(testConfig()).transportRetryAttempts, 0,
          reason: 'composition must not silently opt anyone in');
      expect(
        build(
          testConfig(),
          attempts: 3,
        ).transportRetryAttempts,
        3,
        reason: 'the headless runner forwards config.transportRetryAttempts',
      );
    });

    test('ask_user is wired when the coordinator provides an asker, absent '
        'otherwise', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      AgentDriver build({Future<List<Answer>> Function(List<Question>)? askUser}) =>
          buildAgent(
            pipeline: defaultPipeline,
            scheduler: scheduler,
            conversationId: 'c1',
            provider: FakeProvider(const [], model: 'm'),
            host: FakeHostInterface(),
            policy: config.buildPolicy(),
            config: config,
            askUser: askUser,
          );
      expect(build().tools['ask_user'], isNull);
      expect(
          build(askUser: (questions) async => const []).tools['ask_user'],
          isNotNull);
    });

    test('the auto-compact threshold flows from config into the agent', () {
      // Headless --prompt runs have no SessionController to run the
      // between-turns compaction pass, so the engine's mid-turn auto-compact
      // must be armed straight from --auto-compact-threshold (the default
      // 120000, not the engine's off-by-default 0).
      Agent buildWith(List<String> argv) {
        final config = Config.parse(argv);
        final scheduler = createScheduler(
          config: config,
          registry: ProviderRegistry(env: {}),
          pipeline: defaultPipeline,
        );
        return (buildAgent(
          pipeline: defaultPipeline,
          scheduler: scheduler,
          conversationId: 'c1',
          provider: FakeProvider(const [], model: 'm'),
          host: FakeHostInterface(),
          policy: config.buildPolicy(),
          config: config,
          withSubAgents: false,
        ) as AgentDriverAdapter).agent;
      }

      expect(buildWith(const ['--backend', 'ansi']).autoCompactThreshold,
          120000);
      expect(
          buildWith(const ['--backend', 'ansi', '--auto-compact-threshold',
              '5000']).autoCompactThreshold,
          5000);
      expect(
          buildWith(const ['--backend', 'ansi', '--auto-compact-threshold',
              '0']).autoCompactThreshold,
          0);
    });

    test('the workflow surface is wired in both modes when a supervisor is '
        'provided', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final interactive = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        supervisor: noopSupervisor(),
      );
      final headless = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c2',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        withSubAgents: false,
        supervisor: noopSupervisor(),
      );
      expect(interactive.tools['launch_workflow'], isNotNull);
      expect(interactive.tools['stop_workflow'], isNotNull);
      expect(headless.tools['launch_workflow'], isNotNull);
      expect(headless.tools['stop_workflow'], isNotNull);
    });

    test('every tool schema is a wire-valid JSON-Schema object', () {
      // The full interactive registry — base file tools + orchestration +
      // workflow + region surface — built exactly as the composition builds
      // it, so a NEW tool added anywhere is swept automatically. Providers
      // reject schemas without `"type": "object"` (seen live: DeepSeek 400
      // "Invalid schema for function 'repo_structure' ... got 'type': null"
      // when a tool declared an empty input schema).
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final tmp = Directory.systemTemp.createTempSync('tina-schema-');
      try {
        final driver = buildAgent(
          pipeline: defaultPipeline,
          scheduler: scheduler,
          conversationId: 'c1',
          provider: FakeProvider(const [], model: 'm'),
          host: FakeHostInterface(),
          policy: config.buildPolicy(),
          config: config,
          supervisor: noopSupervisor(),
          regions: RegionRegistry(projectRoot: tmp.path),
          summaryIndex: buildSummaryInspection(projectRoot: tmp.path),
        );
        final schemas = driver.tools.schemas;
        // The sweep is actually sweeping — not vacuously passing over one tool.
        expect(schemas.length, greaterThan(10));
        for (final s in schemas) {
          expect(s.inputSchema['type'], 'object',
              reason: '${s.name} must declare type: object');
          expect(s.inputSchema['properties'], isA<Map>(),
              reason: '${s.name} must declare a properties map');
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('approval identity', () {
    test('every tool this build knows about can be approved knowingly', () {
      // The sibling of the schema sweep above: a tool is not "wired" just
      // because it has a schema — if it can prompt, the user has to be able to
      // see what they are approving, and the remembered answer has to mean
      // something narrower than "yes to everything". Swept over the same
      // composition so a NEW tool is swept automatically, plus the built-in
      // defaults table (a tool like web_search mounts only when its key is
      // configured, but its gate is decided here either way).
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final tmp = Directory.systemTemp.createTempSync('tina-approval-');
      try {
        final driver = buildAgent(
          pipeline: defaultPipeline,
          scheduler: scheduler,
          conversationId: 'c1',
          provider: FakeProvider(const [], model: 'm'),
          host: FakeHostInterface(),
          policy: config.buildPolicy(),
          config: config,
          withSubAgents: true,
          supervisor: noopSupervisor(),
          regions: RegionRegistry(projectRoot: tmp.path),
          summaryIndex: buildSummaryInspection(projectRoot: tmp.path),
        );
        // The composition builds through the default factory, so unwrap its
        // adapter to reach the policy that actually gates the mounted tools.
        final policy =
            driver is AgentDriverAdapter ? driver.agent.policy : null;
        expect(policy, isNotNull,
            reason: 'the default driver must expose the policy that gates it');
        final mounted = {for (final t in driver.tools.all) t.schema.name: t};
        final known = policy!.defaults.keys.toSet();
        final required = {...mounted.keys, ...known};

        // 1. Every tool needs a sample call here, so a new tool has to be
        //    considered rather than slipping through unnoticed.
        expect(_sampleCalls.keys.toSet(), required,
            reason: 'add the new tool to _sampleCalls (or drop the stale '
                'entry) so its approval identity is checked');

        final promptable = <String>{};
        for (final entry in _sampleCalls.entries) {
          final name = entry.key;
          final input = entry.value;
          // A local-control tool is force-allowed by the executor before the
          // policy is consulted, so it never reaches a prompt whatever the
          // policy would say. Only tools that can actually ask are held to the
          // approval-identity invariants.
          final canPrompt = mounted[name] is! LocalControlTool &&
              policy.check(name, input) == PermissionDecision.ask;
          if (!canPrompt) continue;
          promptable.add(name);

          final key = PermissionPolicy.keyFor(name, input);
          final always = PermissionPolicy.defaultAlwaysPatternFor(name, input);
          final problems = <String>[
            if (key.isEmpty)
              'empty approval key: the prompt names no target, and a static '
                  'rule for this tool can never match',
            if (!globMatch(always, key, starMatchesSlash: name == 'bash'))
              'the remembered rule does not match the call it came from, so '
                  '"always" would be a silent no-op',
            if (key.isNotEmpty && always == '*')
              'a call with a real target remembers the universal wildcard',
          ];

          final gap = _knownApprovalGaps[name];
          if (gap == null) {
            expect(problems, isEmpty, reason: '$name: ${problems.join('; ')}');
          } else {
            expect(problems, isNotEmpty,
                reason: 'stale gap entry for $name — "$gap" no longer applies, '
                    'so remove it from _knownApprovalGaps');
          }
        }

        // 2. A gap entry for a tool that cannot prompt would never be checked,
        //    and would sit there looking like a live defect.
        expect(_knownApprovalGaps.keys.toSet().difference(promptable), isEmpty,
            reason: 'gap entries must name tools that can actually prompt');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('a root-level path cannot be remembered (known gap)', () {
      // A file with no directory component has no directory rule to remember:
      // `defaultAlwaysPatternFor` falls back to `*`, which for a file tool
      // compiles to `[^/]*` and so never matches the absolute path it came
      // from — "always" silently does nothing. Delete this test when the
      // directory rule learns to handle root-level files.
      const input = {'filePath': '/foo.txt'};
      final key = PermissionPolicy.keyFor('write', input);
      final always = PermissionPolicy.defaultAlwaysPatternFor('write', input);
      expect(key, '/foo.txt');
      expect(always, '*', reason: 'no directory component to remember');
      expect(globMatch(always, key), isFalse,
          reason: 'the wildcard cannot match an absolute single-segment path');
    });

    test('a permission rule for a tool that is not mounted is reported', () {
      // A rule naming an unavailable tool can never match, so it silently
      // enforces nothing — a typo (`--deny 'bashh:rm *'`) must not look like a
      // working deny. The composition reports it once, at build time.
      final config =
          Config.parse(const ['--backend', 'ansi', '--deny', 'bashh:rm *']);
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final host = FakeHostInterface();
      buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: host,
        policy: config.buildPolicy(),
        config: config,
        supervisor: noopSupervisor(),
      );

      expect(host.messages.any((m) => m.contains('bashh:rm *')), isTrue,
          reason: 'the inert rule is named, so the typo is visible');
      expect(
          host.styledMessages
              .any((m) => m.style == HostMessageStyle.warning),
          isTrue,
          reason: 'and it is a warning, not a dim aside');
    });

    test('a rule for a mounted tool is not reported', () {
      final config =
          Config.parse(const ['--backend', 'ansi', '--deny', 'bash:rm *']);
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final host = FakeHostInterface();
      buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: host,
        policy: config.buildPolicy(),
        config: config,
        supervisor: noopSupervisor(),
      );

      expect(host.messages.any((m) => m.contains('can never match')), isFalse,
          reason: 'bash is mounted, so this rule is doing real work');
    });
  });

  group('buildAgent routes through the resolved driver dependencies', () {
    test('a scope-selected driver factory builds the MAIN agent, and the '
        'factory receives the mounted guards', () async {
      final config = testConfig();
      var factoryCalls = 0;
      var guardChecks = 0;
      _CapturingDriver? builtDriver;
      final factory = _CountingDriverFactory((request) {
        factoryCalls++;
        builtDriver ??= _CapturingDriver(request);
        return builtDriver!;
      }, onGuard: () => guardChecks++);
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
        driverFactory: factory,
        guards: [factory.guard],
      );
      addTearDown(scheduler.dispose);
      expect(scheduler.driverFactory, same(factory),
          reason: 'precondition: the factory is mounted on the scheduler');

      final driver = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
      );
      // The driver the factory built IS what came back — not an agent
      // unwrapped out of it.
      expect(driver, same(builtDriver));

      expect(factoryCalls, 1,
          reason: 'main-agent construction must go through the resolved '
              'factory, exactly like a delegated build');
      expect(scheduler.scopeGuards, contains(factory.guard),
          reason: 'the mounted guard rode the main build request');
      // The guard probe: the built agent's executor chain includes the
      // mounted guard — visible through the request the factory captured.
      final request = builtDriver!.request;
      expect(request.executionGuards, contains(factory.guard));
      // Guard invocation: run one bash call through the built agent and
      // count guard checks at the executor boundary.
      final driver2 = driver as _CapturingDriver;
      driver2.provider = FakeProvider(const [
        [
          MessageComplete(
            content: [
              ToolUseBlock(id: 't1', name: 'bash', input: {'command': 'echo hi'})
            ],
            stopReason: 'tool_use',
          ),
        ],
        [MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn')],
      ], model: 'm');
      final history = <Message>[Message(role: Role.user, content: [TextBlock('hi')])];
      await driver2.run(history: history, userInput: 'hi');
      expect(guardChecks, greaterThanOrEqualTo(1),
          reason: 'the mounted guard must be consulted by the main agent\'s '
              'tool dispatch, not just present in a list');
    });

    test('the default path still builds a working agent through the '
        'factory seam (no factory mounted)', () async {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      addTearDown(scheduler.dispose);
      final driver = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [
          [MessageComplete(content: [TextBlock('ok')], stopReason: 'end_turn')
          ],
        ], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
      );
      expect(driver, isA<AgentDriverAdapter>(),
          reason: 'no factory mounted: the adapter over the plain build');
      expect(driver.tools['read'], isNotNull,
          reason: 'the tool set survives the seam unchanged');
      final history = <Message>[Message(role: Role.user, content: [TextBlock('go')])];
      await driver.run(history: history, userInput: 'go');
      expect(history.last.role, Role.assistant);
    });
  });
}

/// A guard that counts checks and denies nothing.
class _CountingGuard implements ToolGuard {
  final void Function() onCheck;
  _CountingGuard(this.onCheck);

  @override
  String? block(String toolName, Map<String, dynamic> input) {
    onCheck();
    return null;
  }
}

/// A factory that counts create() calls and captures the built driver.
class _CountingDriverFactory implements AgentDriverFactory {
  final AgentDriver? Function(AgentDriverRequest request) build;
  final void Function() onGuard;
  late final _CountingGuard guard = _CountingGuard(onGuard);

  _CountingDriverFactory(this.build, {required this.onGuard});

  @override
  AgentDriver create(AgentDriverRequest request) =>
      build(request) ?? _CapturingDriver(request);
}

/// Records the request it was created from and drives a real inner agent.
class _CapturingDriver implements AgentDriver {
  final AgentDriverRequest request;
  _CapturingDriver(this.request);

  late final Agent _agent = Agent(
    provider: request.provider,
    tools: request.tools,
    sink: request.sink,
    policy: request.policy,
    asker: request.asker,
    maxSteps: request.maxSteps,
    budget: request.budget,
    pauseGate: request.pauseGate,
    system: request.system,
    executionGuards: request.executionGuards,
    executionHooks: request.executionHooks,
    resultHooks: request.resultHooks,
    toolObservers: request.observers,
    resultVerifier: request.resultVerifier,
    onHistoryAppend: request.onHistoryAppend,
    onHistoryReplace: request.onHistoryReplace,
    transportRetryAttempts: request.transportRetryAttempts,
  );

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
    HistoryAppendObserver? onHistoryAppend,
    HistoryReplaceObserver? onHistoryReplace,
  }) =>
      AgentDriverAdapter(_agent).run(
        onHistoryAppend: onHistoryAppend,
        onHistoryReplace: onHistoryReplace,
        history: history,
        userInput: userInput,
        cancelSignal: cancelSignal,
        toolInterruptSignal: toolInterruptSignal,
        turnTools: turnTools,
      );

  @override
  String? get abortedReason => _agent.abortedReason;

  @override
  AbortedKind get abortedKind => _agent.abortedKind;

  @override
  String get system => _agent.system;

  @override
  ToolRegistry get tools => _agent.tools;

  @override
  LlmProvider get provider => _agent.provider;

  @override
  set provider(LlmProvider value) => _agent.provider = value;

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) =>
      _agent.compact(
        history,
        preserveRecent: preserveRecent,
        preserveRecentMessages: preserveRecentMessages,
        cancelSignal: cancelSignal,
      );
}

/// One representative call per tool this build can mount, plus the built-in
/// defaults table, keyed by tool name. The approval-identity sweep requires an
/// entry for every one of them — that is what turns "someone added a tool" into
/// a failing test instead of a silent gap.
///
/// Un-promptable tools only need the entry; their input is never inspected. For
/// a tool that can prompt, the input has to be realistic, because the
/// invariants are checked against it.
const _sampleCalls = <String, Map<String, dynamic>>{
  // Can prompt — checked in detail.
  'bash': {'command': 'git status --short'},
  'exec': {'executable': 'dart', 'args': ['test'], 'cwd': '/p'},
  'write': {'filePath': '/p/lib/a.dart', 'content': 'x'},
  'edit': {'filePath': '/p/lib/a.dart', 'oldString': 'a', 'newString': 'b'},
  'fetch': {'url': 'https://example.com/page'},
  'web_search': {'query': 'dart glob semantics'},
  'launch_workflow': {'workflow': 'lint', 'input': 'run the linter'},
  'broadcast_region': {'task': 'what does this region do?'},
  'forget_region': {'dir': 'lib/tui'},
  // Never prompts: read-only default, orchestration, or a local-control tool
  // the executor force-allows (begin_environment_execution).
  'allocate_region': {'dir': 'lib/tui'},
  'ask_user': {'questions': <Object>[]},
  'begin_environment_execution': {'findings': 'a Dart monorepo'},
  'close': {'channel': 'team'},
  'delegate': {'delegations': <Object>[]},
  'execution_info': <String, dynamic>{},
  'git': <String, dynamic>{},
  'glob': {'filePath': '/p/lib'},
  'grep': {'pattern': 'TODO'},
  'list_regions': <String, dynamic>{},
  'ls': {'filePath': '/p'},
  'query_region': {'task': 'what does this region do?'},
  'read': {'filePath': '/p/lib/a.dart'},
  'read_summary': <String, dynamic>{},
  'receive': {'channel': 'team'},
  'render_image': {'filePath': '/p/x.png'},
  'repo_structure': <String, dynamic>{},
  'search': {'query': 'approval'},
  'send': {'channel': 'team', 'message': 'hi'},
  'stat': {'filePath': '/p/lib/a.dart'},
  'stop_workflow': <String, dynamic>{},
  'which': {'command': 'dart'},
  'write_summary': {'filePath': '/p/lib/a.dart'},
};

/// Promptable tools whose approval identity is weaker than the invariants the
/// sweep enforces. Stage 0 records them here so the suite is green while the
/// gaps are tracked: every entry must still be violating (the sweep fails on a
/// stale entry) and each one is deleted as part of fixing it.
const _knownApprovalGaps = <String, String>{

  'fetch': 'keyFor has no case for `url`: the header names no target and '
      '"always" is the wildcard.',
  'web_search': 'keyFor has no case for `query`: the same shape as fetch.',
  'broadcast_region': 'the input is `task`, but the key falls through to the '
      'file-path case, so there is nothing to show or remember.',
  'forget_region': 'the input is `dir`, but the key falls through to the '
      'file-path case, so there is nothing to show or remember.',
  'launch_workflow': 'keyFor uses the workflow name, but the "always" pattern '
      'falls through to "*", so approving one workflow approves every workflow.',
};
