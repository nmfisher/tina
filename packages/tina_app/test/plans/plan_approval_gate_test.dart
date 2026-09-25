import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';

/// Pins the unattended-run fix for plan approvals (2026-09-24 stall): the
/// plan-approval gate is a HUMAN gate — `approval: "requested"` parks the
/// plan and the request middleware tells the agent to wait. Two postures
/// must never park:
///
/// - `--yolo` (`allowAllByDefault`): the flag documents "skip all permission
///   prompts", and the plan gate is a permission prompt. The tool must
///   auto-grant instead of parking, and the middleware must say the plan is
///   approved — never "wait".
/// - No answerable human: a headless host (`--prompt`, `--workflow`) has no
///   `/plan` and no overlay. Parking there can only stall the run forever,
///   so the tool auto-grants too.
///
/// The interactive default keeps the gate: a normal TUI run still parks on
/// `approval: "requested"` and still shows the wait instruction.
void main() {
  late PlanStore store;
  setUp(() {
    store = PlanStore();
  });
  tearDown(() {
    store.dispose();
  });

  /// A plan middleware over [store] with an optional yolo policy + host,
  /// mirroring how buildAgent wires it.
  PlanMiddleware middleware({
    bool yolo = false,
    HostInterface? host,
  }) =>
      PlanMiddleware(
        store,
        'c1',
        policy: yolo
            ? PermissionPolicy(mode: PermissionMode.ask, allowAllByDefault: true)
            : null,
        host: host,
      );

  Future<String> section(PlanMiddleware mw) async {
    final decision = await mw.beforeRequest(
      AgentContext(
        stage: AgentStage.request,
        cwd: '.',
        loadWorkspaceContext: false,
        model: 'test-model',
      ),
      AgentRequest(system: 'base', messages: [], tools: []),
    );
    if (decision.action != AgentAction.next || decision.value == null) {
      fail('expected a next decision carrying a request');
    }
    return decision.value!.system;
  }

  group('PlanTool approval gate', () {
    test('--yolo (allowAllByDefault) auto-grants instead of parking',
        () async {
      final tool = PlanTool(
        store,
        'c1',
        policy:
            PermissionPolicy(mode: PermissionMode.ask, allowAllByDefault: true),
      );
      final r = await tool.execute({
        'items': [
          {'text': 'step one', 'state': 'pending'},
          {'text': 'step two', 'state': 'in_progress'},
        ],
        'approval': 'requested',
      });
      expect(r.isError, isFalse);
      // The tool must NOT report "waiting for user approval".
      expect(r.content, isNot(contains('waiting for user approval')));
      final plan = store.read('c1');
      expect(plan.approval, PlanApproval.approved,
          reason: 'yolo grants the plan so the run keeps moving');
    });

    test('--yolo auto-grants an approval-only re-request too', () async {
      store.update('c1', [PlanItem('a', state: PlanState.pending)]);
      final tool = PlanTool(
        store,
        'c1',
        policy:
            PermissionPolicy(mode: PermissionMode.ask, allowAllByDefault: true),
      );
      final r = await tool.execute({'approval': 'requested'});
      expect(r.isError, isFalse);
      expect(store.read('c1').approval, PlanApproval.approved);
      expect(r.content, isNot(contains('waiting')));
    });

    test('headless host (no answerable human) auto-grants', () async {
      final tool = PlanTool(store, 'c1', host: FakeHeadlessHost());
      final r = await tool.execute({
        'items': [
          {'text': 'step one', 'state': 'pending'},
        ],
        'approval': 'requested',
      });
      expect(r.isError, isFalse);
      expect(store.read('c1').approval, PlanApproval.approved,
          reason: 'nobody can answer; parking would stall forever');
    });

    test('interactive default keeps the gate: requested parks, not approves',
        () async {
      final tool = PlanTool(store, 'c1', host: FakeAnsweringHost());
      final r = await tool.execute({
        'items': [
          {'text': 'step one', 'state': 'pending'},
        ],
        'approval': 'requested',
      });
      expect(r.isError, isFalse);
      expect(r.content, contains('waiting for user approval'));
      final plan = store.read('c1');
      expect(plan.approval, PlanApproval.requested);
      expect(plan.needsApproval, isTrue);
    });

    test('interactive + explicit ask policy still parks (mode stays readable)',
        () async {
      final tool = PlanTool(store, 'c1', host: FakeAnsweringHost());
      final r = await tool.execute({
        'items': [
          {'text': 'step one', 'state': 'pending'},
        ],
        'approval': 'requested',
      });
      expect(store.read('c1').approval, PlanApproval.requested);
      expect(r.content, contains('waiting for user approval'));
    });

    test('items without approval under --yolo just update (no gate touched)',
        () async {
      final tool = PlanTool(
        store,
        'c1',
        policy:
            PermissionPolicy(mode: PermissionMode.ask, allowAllByDefault: true),
      );
      final r = await tool.execute({
        'items': [
          {'text': 'step one', 'state': 'pending'},
        ],
      });
      expect(r.isError, isFalse);
      expect(store.read('c1').approval, PlanApproval.none);
    });
  });

  group('PlanMiddleware approval guidance', () {
    test('--yolo never tells the agent to wait', () async {
      store.update(
        'c1',
        [PlanItem('step one', state: PlanState.inProgress)],
        approval: PlanApproval.approved,
      );
      final system = await section(middleware(yolo: true));
      expect(system, contains('<current-plan>'));
      expect(system, contains('approved'));
      expect(system, isNot(contains('wait for')));
    });

    test('headless host never tells the agent to wait', () async {
      store.update(
        'c1',
        [PlanItem('step one', state: PlanState.inProgress)],
        approval: PlanApproval.approved,
      );
      final system = await section(middleware(host: FakeHeadlessHost()));
      expect(system, isNot(contains('wait for')));
    });

    test('interactive keeps the wait instruction on a requested plan',
        () async {
      store.update(
        'c1',
        [PlanItem('step one', state: PlanState.inProgress)],
        approval: PlanApproval.requested,
      );
      final system = await section(middleware());
      expect(system, contains('wait for their approval'));
    });
  });
}

/// A host with no answerable human — the shape `HeadlessHost` reports under
/// `--prompt` / `--workflow`. Lives here (not in helpers/) because the
/// capability default on `FakeHostInterface` is the interactive one and most
/// host tests should keep it.
class FakeHeadlessHost extends FakeHostInterface {
  @override
  bool get canAnswerQuestions => false;
}

/// The interactive shape: a human can answer (TUI default).
class FakeAnsweringHost extends FakeHostInterface {}
