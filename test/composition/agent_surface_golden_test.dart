import 'dart:convert';
import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import 'package:tina/config.dart';

import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Golden pins for the plugin-first-tools program
/// (docs/proposals/plugin-first-tools/README.md): for the default config,
/// each build shape's tool list and resolved permission decisions are
/// BYTE-IDENTICAL across PT0/PT1/PT2. These tests are the "byte-identical
/// to WHAT" — captured while buildAgent is still the hand-wired assembly
/// line. A refactor that changes an expected string here has changed user
/// -visible behavior; that is a spec violation, not a golden to bump.
///
/// Four shapes (README invariant): interactive main, maximal interactive
/// main (workflow + regions + asker), headless worker, orchestrator turn.
void main() {
  Config baseConfig() => Config.parse(const ['--backend', 'ansi']);
  Config workflowConfig() =>
      Config.parse(const ['--backend', 'ansi', '--enable-workflow']);

  RunWorkflow noopRun() =>
      ({required workflowName, required sink, required conversationId, input,
          history, cancelSignal, onEvent}) async =>
          PipelineRunResult(outcome: const Outcome.success(), runDir: '');

  /// One representative input per tool name, so a decision can be resolved
  /// for every gate (mirrors the approval-identity sweep's sample calls).
  const sampleCalls = <String, Map<String, dynamic>>{
    'bash': {'command': 'git status --short'},
    'exec': {'executable': 'dart', 'args': ['test'], 'cwd': '/p'},
    'write': {'filePath': '/p/lib/a.dart', 'content': 'x'},
    'edit': {'filePath': '/p/lib/a.dart', 'oldString': 'a', 'newString': 'b'},
    'fetch': {'url': 'https://example.com/page'},
    'web_search': {'query': 'dart glob semantics'},
    'launch_workflow': {'workflow': 'lint', 'input': 'run the linter'},
    'broadcast_region': {'task': 'what does this region do?'},
    'forget_region': {'dir': 'lib/tui'},
    'allocate_region': {'dir': 'lib/tui'},
    'ask_user': {'questions': <Object>[]},
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

  /// The serialized golden for one build: ordered tool names, then the
  /// resolved decision for every mounted tool and every named default gate.
  String golden(AgentDriver driver) {
    final policy =
        driver is AgentDriverAdapter ? driver.agent.policy : driver.policy;
    final mounted = [for (final t in driver.tools.all) t.schema.name];
    final gates = {...mounted, ...policy.defaults.keys};
    final decisions = [
      for (final name in gates)
        '$name=${policy.check(name, sampleCalls[name] ?? const {}).name}',
    ]..sort();
    return jsonEncode({
      'tools': mounted,
      'decisions': decisions,
    });
  }

  AgentDriver buildShape(
    Config config, {
    required bool interactive,
    WorkflowSupervisor? supervisor,
    RegionRegistry? regions,
    SummaryInspection? summaryIndex,
    Future<List<Answer>> Function(List<Question>)? askUser,
    ExploreProjectTool? exploreProject,
  }) {
    final scheduler = createScheduler(
      config: config,
      registry: ProviderRegistry(env: {}),
      pipeline: defaultPipeline,
    );
    addTearDown(scheduler.dispose);
    return buildAgent(
      pipeline: defaultPipeline,
      scheduler: scheduler,
      conversationId: 'c1',
      provider: FakeProvider(const [], model: 'm'),
      host: FakeHostInterface(),
      policy: config.buildPolicy(),
      config: config,
      withSubAgents: interactive,
      supervisor: supervisor,
      regions: regions,
      summaryIndex: summaryIndex,
      askUser: askUser,
      exploreProject: exploreProject,
    );
  }

  test('interactive main (minimal wiring)', () {
    final g = golden(buildShape(baseConfig(), interactive: true));
    expect(g, _interactiveMinimal, reason: _reason);
  });

  test('interactive main (maximal wiring: workflow, regions, asker)', () {
    final tmp = Directory.systemTemp.createTempSync('tina-golden-');
    try {
      final g = golden(buildShape(
        workflowConfig(),
        interactive: true,
        supervisor: WorkflowSupervisor(run: noopRun()),
        regions: RegionRegistry(workspaceRoot: tmp.path),
        summaryIndex: buildSummaryInspection(workspaceRoot: tmp.path),
        askUser: (questions) async => const [],
      ));
      expect(g, _interactiveMaximal, reason: _reason);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('headless worker (withSubAgents: false)', () {
    final g = golden(buildShape(baseConfig(), interactive: false));
    expect(g, _headless, reason: _reason);
  });

  test('orchestrator turn', () {
    final tmp = Directory.systemTemp.createTempSync('tina-golden-');
    try {
      final base = buildShape(
        workflowConfig(),
        interactive: true,
        supervisor: WorkflowSupervisor(run: noopRun()),
        regions: RegionRegistry(workspaceRoot: tmp.path),
        summaryIndex: buildSummaryInspection(workspaceRoot: tmp.path),
        askUser: (questions) async => const [],
        exploreProject: ExploreProjectTool(open: () => null),
      );
      final turn = explorationToolsForTurn(
        base.tools,
        explorationTurnPrompt('what owns the gutter rendering?'),
      );
      expect(turn, isNotNull, reason: 'the exploration prefix must route');
      final names = [for (final t in turn!.all) t.schema.name]..sort();
      expect(jsonEncode(names), _orchestrator, reason: _reason);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

const _reason =
    'the default-config surface changed. If the change is intentional, update '
    'the golden AND note it in docs/proposals/plugin-first-tools/README.md — '
    'these pins are the baseline the plugin migration must reproduce.';

const _interactiveMinimal =
    '{"tools":["read","write","edit","fetch","bash","exec","execution_info","search","grep","glob","ls","stat","which","git","render_image","delegate","send","receive","close"],"decisions":["allocate_region=allow","ask_user=allow","bash=ask","close=allow","delegate=allow","edit=ask","exec=ask","execution_info=allow","fetch=ask","git=allow","glob=allow","grep=allow","list_regions=allow","ls=allow","query_region=allow","read=allow","read_summary=allow","receive=allow","render_image=allow","repo_structure=allow","search=allow","send=allow","stat=allow","stop_workflow=allow","web_search=ask","which=allow","write=ask","write_summary=allow"]}';

const _interactiveMaximal =
    '{"tools":["read","write","edit","fetch","bash","exec","execution_info","search","grep","glob","ls","stat","which","git","launch_workflow","stop_workflow","repo_structure","list_regions","read_summary","query_region","broadcast_region","allocate_region","forget_region","ask_user","render_image","delegate","send","receive","close"],"decisions":["allocate_region=allow","ask_user=allow","bash=ask","broadcast_region=ask","close=allow","delegate=allow","edit=ask","exec=ask","execution_info=allow","fetch=ask","forget_region=ask","git=allow","glob=allow","grep=allow","launch_workflow=ask","list_regions=allow","ls=allow","query_region=allow","read=allow","read_summary=allow","receive=allow","render_image=allow","repo_structure=allow","search=allow","send=allow","stat=allow","stop_workflow=allow","web_search=ask","which=allow","write=ask","write_summary=allow"]}';

const _headless =
    '{"tools":["read","write","edit","fetch","bash","exec","execution_info","search","grep","glob","ls","stat","which","git"],"decisions":["allocate_region=ask","bash=ask","edit=ask","exec=ask","execution_info=allow","fetch=ask","git=allow","glob=allow","grep=allow","list_regions=allow","ls=allow","query_region=allow","read=allow","read_summary=allow","render_image=allow","repo_structure=allow","search=allow","stat=allow","web_search=ask","which=allow","write=ask","write_summary=allow"]}';

const _orchestrator = '["ask_user","explore_project"]';
