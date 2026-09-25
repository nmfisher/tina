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

  /// The same posture the conversation's [PlanTool] resolved (yolo posture /
  /// host answerability): an auto-granted run must never be told to wait for
  /// an approval nobody can give — that instruction is the 2026-09-24 stall.
  final PlanApprovalMode approvalMode;

  PlanMiddleware(
    this.store,
    this.conversationId, {
    PermissionPolicy? policy,
    HostInterface? host,
  }) : approvalMode = PlanTool.resolveApprovalMode(policy, host);

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
      request.copyWith(
        system: '${request.system}\n${_section(plan, approvalMode)}',
      ),
    );
  }
}

String _section(Plan plan, PlanApprovalMode approvalMode) {
  final buffer = StringBuffer(
    '<current-plan>\n'
    'This conversation maintains a task plan with the update_plan tool.\n'
    'Keep exactly one item in_progress; move items to done only when their '
    'work is finished; call update_plan whenever the plan changes.\n',
  );
  buffer.writeln(switch (plan.approval) {
    PlanApproval.none =>
      'Approval has not been requested for this plan.',
    // An auto-granting run must never see "wait" — an unattended run would
    // take the instruction literally and stall (2026-09-24).
    PlanApproval.requested when approvalMode == PlanApprovalMode.autoGrant =>
      'Approval was requested but this run has no user to answer: proceed '
          'with the work.',
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
    // Subtasks render indented under their parent, mirroring the overlay.
    for (final child in item.children) {
      buffer.writeln('  ${switch (child.state) {
        PlanState.pending => '[ ]',
        PlanState.inProgress => '[~]',
        PlanState.done => '[x]',
      }} ${child.text}');
    }
  }
  buffer.writeln('</current-plan>');
  return buffer.toString();
}

/// The agent's write surface. Implements [LocalControlTool]: it mutates only
/// plugin-local orchestration state, so the executor allows it without an
/// approval ask (tool_executor.dart short-circuits `is LocalControlTool`)
/// while the guard chain applies.
///
/// The plan-approval dimension is a HUMAN gate — separate from the tool
/// permission policy. When no human is in the loop, a request must not park
/// the run (2026-09-24: an unattended `--yolo --prompt` run stalled forever
/// waiting on an approval nobody could give), so the mode is resolved at
/// construction and a `requested` ask auto-grants instead:
///
/// - `--yolo` (`PermissionPolicy.allowAllByDefault`): the flag documents
///   "skip all permission prompts", and this is one.
/// - The host has no answerable human ([HostInterface.canAnswerQuestions]
///   is false — headless `--prompt`/`--workflow`): there is no `/plan` and
///   no overlay to answer through.
///
/// Otherwise (interactive default) `requested` parks the plan exactly as
/// before and the user answers via `/plan` or the overlay.
enum PlanApprovalMode { interactive, autoGrant }

class PlanTool extends LocalControlTool {
  final PlanStore store;
  final String conversationId;

  /// The conversation's permission policy — read once for the `--yolo`
  /// posture (`allowAllByDefault`). Null in tests/when no policy exists
  /// (same as a non-yolo posture).
  final PermissionPolicy? policy;

  /// The conversation's host. Read once for answerability — a headless host
  /// auto-grants even without `--yolo`, because nobody could ever answer.
  final HostInterface? host;

  /// Resolved once at construction: policy and answerability are fixed for
  /// the conversation's lifetime (the policy's yolo posture is set at
  /// startup and the host does not change mid-session).
  final PlanApprovalMode approvalMode;

  /// The shared mode resolver: `--yolo` posture (`allowAllByDefault`) or an
  /// unanswerable host forces [PlanApprovalMode.autoGrant]; anything else
  /// keeps the interactive gate. Static so [PlanMiddleware] resolves the
  /// identical mode from the same two signals — the tool and the guidance
  /// must never disagree about whether the run can wait.
  static PlanApprovalMode resolveApprovalMode(
    PermissionPolicy? policy,
    HostInterface? host,
  ) =>
      (policy?.allowAllByDefault ?? false) ||
              !(host?.canAnswerQuestions ?? true)
          ? PlanApprovalMode.autoGrant
          : PlanApprovalMode.interactive;

  PlanTool(
    this.store,
    this.conversationId, {
    this.policy,
    this.host,
  }) : approvalMode = resolveApprovalMode(policy, host);

  @override
  ToolSchema get schema => ToolSchema(
        name: 'update_plan',
        description:
            'Replace this conversation\'s task plan. Pass the complete item '
            'list with each item\'s state (pending, in_progress, done). An '
            'item may carry a flat `children` list of subtask items (one '
            'nesting level; children must not have children). Keep at most '
            'one item in_progress across the whole plan (children included). '
            'Use it to track multi-step work for the user; call it again '
            'whenever the plan changes. Pass approval: "requested" to ask '
            'the user to approve the plan before you execute it — they '
            'approve or reject via /plan, and the plan you see in context '
            'tells you the outcome. You may also call it with only '
            'approval: "requested" to (re-)request approval for the '
            'unchanged plan.',
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
              // The per-item shape; one nesting level via its own `children`.
              'items': _itemSchema(allowChildren: true),
            },
          },
          'required': ['items'],
        },
      );

  /// The JSON schema of one plan item. Root rows may carry [children];
  /// children must be childless (nesting is capped at one level), which the
  /// child shape enforces structurally.
  static Map<String, dynamic> _itemSchema({required bool allowChildren}) => {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'state': {
            'type': 'string',
            'enum': ['pending', 'in_progress', 'done'],
          },
          if (allowChildren)
            'children': {
              'type': 'array',
              'description':
                  'Optional subtasks of this item. One nesting level: '
                  'children must not carry children of their own.',
              'items': _itemSchema(allowChildren: false),
            },
        },
        'required': ['text', 'state'],
      };

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
    // No human in the loop (yolo / unattended): a request must not park the
    // run — auto-grant so the work proceeds (2026-09-24 plan stall).
    final effectiveApproval =
        approval == PlanApproval.requested &&
                approvalMode == PlanApprovalMode.autoGrant
            ? PlanApproval.approved
            : approval;
    // Approval-only call: re-request on the unchanged plan, no items needed.
    if (rawItems == null) {
      if (approval != PlanApproval.requested) {
        return ToolResult.error(
            'update_plan requires an items array (or approval: "requested")');
      }
      try {
        switch (effectiveApproval) {
          case PlanApproval.approved:
            store.approve(conversationId);
          case PlanApproval.requested:
            store.requestApproval(conversationId);
          default:
            throw StateError('no plan to approve');
        }
      } on StateError {
        return ToolResult.error('no plan to approve');
      }
      return ToolResult(switch (effectiveApproval) {
        PlanApproval.approved =>
          'Plan unchanged; proceeding (no user approval is possible or '
              'required in this run).',
        _ => 'Plan unchanged; approval requested.',
      });
    }
    if (rawItems is! List) {
      return ToolResult.error('update_plan requires an items array');
    }
    try {
      final items = [
        for (final raw in rawItems) _decodeItem(raw, allowChildren: true),
      ];
      store.update(conversationId, items, approval: effectiveApproval);
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
      PlanApproval.approved when approvalMode == PlanApprovalMode.autoGrant =>
        'Plan updated; approved automatically (no user approval is possible '
            'or required in this run).',
      _ => 'Plan updated.',
    });
  }

  /// Decode one model-supplied item into a [PlanItem], preserving its
  /// existing strict decode contract: missing/junk text or state is a tool
  /// error, unknown children entries are tool errors too. When
  /// [allowChildren] is false (a child row) any nested `children` payload is
  /// rejected — the tool surfaces one nesting level as an error instead of
  /// silently flattening it.
  static PlanItem _decodeItem(
    dynamic raw, {
    required bool allowChildren,
  }) {
    final text = switch (raw) {
      {'text': String text} => text,
      _ => throw ArgumentError('plan item requires string text'),
    };
    final state = switch (raw) {
      {'state': 'pending'} => PlanState.pending,
      {'state': 'in_progress'} => PlanState.inProgress,
      {'state': 'done'} => PlanState.done,
      _ => throw ArgumentError(
          'plan item state must be pending, in_progress or done'),
    };
    final children = <PlanItem>[];
    final rawChildren = switch (raw) {
      {'children': final List rawChildren} => rawChildren,
      // Present but not a list (null included) is a tool error; absent is
      // simply no children.
      {'children': _} =>
        throw ArgumentError('plan item children must be an array'),
      _ => const <dynamic>[],
    };
    if (rawChildren.isNotEmpty && !allowChildren) {
      throw ArgumentError('plan supports one nesting level only '
          '(children of children)');
    }
    for (final rawChild in rawChildren) {
      children.add(_decodeItem(rawChild, allowChildren: false));
    }
    return PlanItem(text, state: state, children: children);
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

/// Strip view-model: the item list (parents with their children), the
/// approval dimension, and derived counts, kept value-shaped so the renderer
/// stays a pure function. The done/total counts span children: subtasks are
/// plan work, so the strip reports all of it.
class PlanSummary {
  final List<PlanItem> items;
  final PlanApproval approval;
  const PlanSummary(this.items, {this.approval = PlanApproval.none});

  Iterable<PlanItem> get _all sync* {
    for (final item in items) {
      yield item;
      yield* item.children;
    }
  }

  int get done => _all.where((i) => i.state == PlanState.done).length;
  int get total => _all.length;
  String? get active =>
      _all.where((i) => i.state == PlanState.inProgress).firstOrNull?.text;
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
          // Deliberately top-level only: dotted child addressing
          // (`/plan done 2.1`) is out of scope for v1 — the overlay's
          // space key or a model update_plan call edits children.
          if (index < 0 || index >= plan.items.length) {
            call.write('No plan item ${index + 1}.\n');
            return const CmdHandled(failed: true);
          }
          try {
            store.update(id, [
              for (final (i, item) in plan.items.indexed)
                i == index
                    ? item.copyWith(
                        state: verb == 'done'
                            ? PlanState.done
                            : PlanState.pending)
                    : item,
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
    store.update(id, [...existing, PlanItem(text, state: PlanState.pending)]);
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
    // Subtasks show indented and unnumbered: `/plan done <n>` addresses
    // top-level items only (dotted addressing is out of scope for v1).
    for (final child in item.children) {
      buffer.writeln('      ${switch (child.state) {
        PlanState.pending => '[ ]',
        PlanState.inProgress => '[~]',
        PlanState.done => '[x]',
      }} ${child.text}');
    }
  }
  call.write(buffer.toString());
}
