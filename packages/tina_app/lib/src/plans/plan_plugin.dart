import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import '../commands/command_context.dart';
import '../commands/command_registry.dart';
import '../execution/input_status.dart';
import 'plan_store.dart';

export 'plan_store.dart';

/// The service key sibling code uses to require the store; the composition
/// plugin provides it at activation.
final planStoreServiceKey = ServiceKey<PlanStore>('tina.plan.store');

/// One conversation's plan rendered as agent-visible request context,
/// appended to the system prompt per request by [PlanMiddleware].
/// Request-time (deliberately not a PromptContributor): prompts are resolved
/// once per conversation and replayed from stored meta on resume, so a static
/// section would freeze the plan at conversation start.
class PlanMiddleware extends AgentMiddleware {
  final PlanStore store;

  /// The conversation this middleware was built for. Shared-scope
  /// contributions cannot tell whose plan to inject — and two live
  /// conversations must not overwrite each other's context.
  final String conversationId;
  PlanMiddleware(this.store, this.conversationId);

  @override
  String get id => 'tina.plan.middleware';

  @override
  String get name => 'Plan tracker';

  @override
  FutureOr<AgentDecision<AgentRequest>> beforeRequest(
    AgentContext context,
    AgentRequest request,
  ) async {
    if (context.stage != AgentStage.request) return AgentDecision.next(request);
    final plan = store.read(conversationId);
    if (plan.isEmpty) return AgentDecision.next(request);
    return AgentDecision.next(
      request.copyWith(system: '${request.system}\n${_section(plan)}'),
    );
  }
}

String _section(Plan plan) {
  final buffer = StringBuffer(
    '<current-plan>\n'
    'This conversation maintains a task plan with the update_plan tool.\n'
    'Keep exactly one item in_progress; move items to done only when their '
    'work is finished; call update_plan whenever the plan changes.\n',
  );
  buffer.writeln(switch (plan.approval) {
    PlanApproval.none =>
      'Approval has not been requested for this plan.',
    PlanApproval.requested =>
      'You asked the user to approve this plan and they have not answered '
          'yet: wait for their approval before doing the planned work.',
    PlanApproval.approved =>
      'The user approved this plan: proceed with the work.',
    PlanApproval.rejected =>
      'The user rejected this plan: revise it (update_plan replaces the '
          'plan and clears approval), then ask again.',
  });
  for (final item in plan.items) {
    buffer.writeln('${switch (item.state) {
      PlanState.pending => '[ ]',
      PlanState.inProgress => '[~]',
      PlanState.done => '[x]',
    }} ${item.text}');
  }
  buffer.writeln('</current-plan>');
  return buffer.toString();
}

/// The agent's write surface. Implements [LocalControlTool]: it mutates only
/// plugin-local orchestration state, so the executor allows it without an
/// approval ask (tool_executor.dart short-circuits `is LocalControlTool`)
/// while the guard chain still applies.
class PlanTool extends LocalControlTool {
  final PlanStore store;
  final String conversationId;
  PlanTool(this.store, this.conversationId);

  @override
  ToolSchema get schema => ToolSchema(
        name: 'update_plan',
        description:
            'Replace this conversation\'s task plan. Pass the complete item '
            'list with each item\'s state (pending, in_progress, done). Keep '
            'at most one item in_progress. Use it to track multi-step work '
            'for the user; call it again whenever the plan changes. Pass '
            'approval: "requested" to ask the user to approve the plan '
            'before you execute it — they approve or reject via /plan, and '
            'the plan you see in context tells you the outcome. You may also '
            'call it with only approval: "requested" to (re-)request approval '
            'for the unchanged plan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'approval': {
              'type': 'string',
              'enum': ['requested', 'none'],
              'description':
                  '"requested" asks the user to approve this plan before '
                  'work starts. Editing item content clears approval again.',
            },
            'items': {
              'type': 'array',
              'maxItems': PlanStore.maxItems,
              'items': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'},
                  'state': {
                    'type': 'string',
                    'enum': ['pending', 'in_progress', 'done'],
                  },
                },
                'required': ['text', 'state'],
              },
            },
          },
          'required': ['items'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final rawItems = input['items'];
    final approval = switch (input['approval']) {
      null || 'none' => PlanApproval.none,
      'requested' => PlanApproval.requested,
      _ => null, // invalid value → error below
    };
    if (approval == null) {
      return ToolResult.error(
          'update_plan approval must be "requested" or "none"');
    }
    // Approval-only call: re-request on the unchanged plan, no items needed.
    if (rawItems == null) {
      if (approval != PlanApproval.requested) {
        return ToolResult.error(
            'update_plan requires an items array (or approval: "requested")');
      }
      try {
        store.requestApproval(conversationId);
      } on StateError {
        return ToolResult.error('no plan to approve');
      }
      return ToolResult('Plan unchanged; approval requested.');
    }
    if (rawItems is! List) {
      return ToolResult.error('update_plan requires an items array');
    }
    try {
      final items = [
        for (final raw in rawItems)
          (
            text: switch (raw) {
              {'text': String text} => text,
              _ => throw ArgumentError('plan item requires string text'),
            },
            state: switch (raw) {
              {'state': 'pending'} => PlanState.pending,
              {'state': 'in_progress'} => PlanState.inProgress,
              {'state': 'done'} => PlanState.done,
              _ => throw ArgumentError(
                  'plan item state must be pending, in_progress or done'),
            },
          ),
      ];
      store.update(conversationId, items, approval: approval);
    } on ArgumentError catch (error) {
      return ToolResult.error(error.message?.toString() ?? 'invalid plan');
    }
    final plan = store.read(conversationId);
    if (plan.isEmpty) return ToolResult('Plan cleared.');
    return ToolResult(switch (plan.approval) {
      PlanApproval.requested =>
        'Plan updated; waiting for user approval (they will answer via '
            '/plan or the plan overlay; the plan in your context tells you '
            'the outcome).',
      _ => 'Plan updated.',
    });
  }
}

/// The user's glanceable surface: exposes the focused conversation's plan to
/// the strip; the frontend's [Renderer] for [PlanSummary] lives in the root
/// package (tina_app has no console dependency), registered by the same
/// composition plugin.
class PlanStatusSource implements StatusSource {
  final PlanStore store;
  PlanStatusSource(this.store);

  @override
  Object? read(String conversationId) {
    final plan = store.read(conversationId);
    if (plan.isEmpty) return null;
    return PlanSummary(plan.items, approval: plan.approval);
  }

  @override
  Stream<void> get changes => store.changes;
}

/// Strip view-model: the item list, the approval dimension, and derived
/// counts, kept value-shaped so the renderer stays a pure function.
class PlanSummary {
  final List<({String text, PlanState state})> items;
  final PlanApproval approval;
  const PlanSummary(this.items, {this.approval = PlanApproval.none});

  int get done => items.where((i) => i.state == PlanState.done).length;
  int get total => items.length;
  String? get active =>
      items.where((i) => i.state == PlanState.inProgress).firstOrNull?.text;
  bool get needsApproval => approval == PlanApproval.requested;
}

/// The human override. Writes the store directly; every subcommand answers in
/// the invoking conversation.
Command planCommand(PlanStore store) => Command(
      names: ['/plan'],
      argsHint:
          '[clear | done <n> | pending <n> | add <text> | approve | reject | '
          'request-approval | <free text>]',
      summary: 'show or edit the conversation plan (approve/reject when the '
          'agent asks for sign-off)',
      helpOrder: 45,
      handler: (call) async {
        final id = call.conversationId;
        final args = call.arguments.trim();
        if (args.isEmpty) {
          _show(call, store.read(id));
          return const CmdHandled();
        }
        if (RegExp(r'^clear$', caseSensitive: false).hasMatch(args)) {
          store.clear(id);
          call.write('Plan cleared.\n');
          return const CmdHandled();
        }
        final approvalOp = RegExp(
          r'^(approve|reject|request-approval)$',
          caseSensitive: false,
        ).firstMatch(args);
        if (approvalOp != null) {
          final plan = store.read(id);
          if (plan.isEmpty) {
            call.write('No plan to ${approvalOp.group(1)!}.\n');
            return const CmdHandled(failed: true);
          }
          switch (approvalOp.group(1)!.toLowerCase()) {
            case 'approve':
              store.approve(id);
            case 'reject':
              store.reject(id);
            case 'request-approval':
              store.requestApproval(id);
          }
          _show(call, store.read(id));
          return const CmdHandled();
        }
        final toggle = RegExp(
          r'^(done|pending)\s+(\d+)$',
          caseSensitive: false,
        ).firstMatch(args);
        if (toggle != null) {
          final verb = toggle.group(1)!.toLowerCase();
          final index = int.parse(toggle.group(2)!) - 1;
          final plan = store.read(id);
          if (index < 0 || index >= plan.items.length) {
            call.write('No plan item ${index + 1}.\n');
            return const CmdHandled(failed: true);
          }
          try {
            store.update(id, [
              for (final (i, item) in plan.items.indexed)
                (
                  text: item.text,
                  state: i == index
                      ? (verb == 'done' ? PlanState.done : PlanState.pending)
                      : item.state,
                ),
            ]);
          } on ArgumentError catch (error) {
            call.write('${error.message}\n', style: HostMessageStyle.warning);
            return const CmdHandled(failed: true);
          }
          _show(call, store.read(id));
          return const CmdHandled();
        }
        final added =
            RegExp(r'^add\s+(.+)$', caseSensitive: false).firstMatch(args);
        // Free text falls through as one new pending item.
        _append(call, id, store, added?.group(1)?.trim() ?? args);
        return const CmdHandled();
      },
    );

void _append(CommandCall call, String id, PlanStore store, String text) {
  final existing = store.read(id).items;
  try {
    store.update(id, [...existing, (text: text, state: PlanState.pending)]);
  } on ArgumentError catch (error) {
    call.write('${error.message}\n', style: HostMessageStyle.warning);
    return;
  }
  _show(call, store.read(id));
}

void _show(CommandCall call, Plan plan) {
  if (plan.isEmpty) {
    call.write('No plan. `/plan add <text>` starts one; the agent maintains '
        'it with update_plan.\n');
    return;
  }
  final buffer = StringBuffer('Plan:\n');
  if (plan.needsApproval) buffer.writeln('  approval: REQUESTED');
  if (plan.isApproved) buffer.writeln('  approval: approved');
  if (plan.approval == PlanApproval.rejected) {
    buffer.writeln('  approval: rejected');
  }
  for (final (i, item) in plan.items.indexed) {
    buffer.writeln('  ${i + 1}. ${switch (item.state) {
      PlanState.pending => '[ ]',
      PlanState.inProgress => '[~]',
      PlanState.done => '[x]',
    }} ${item.text}');
  }
  call.write(buffer.toString());
}
