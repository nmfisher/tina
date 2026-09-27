/// The session's plan: the tracked task list the agent maintains with the
/// `update_plan` tool, surfaced to the model as a prompt section and to
/// the user as the `/plan` command.
///
/// Ported from the old app's plan plugin, with the truth moved onto this
/// engine's one log: the old engine kept plans in a side map mirrored
/// into a session manifest; here every change appends a
/// [PlanChangedEntry] through `AgentLoop.recordState`, the entry **is**
/// the plan (the latest one wins), and a resume derives it the same way
/// the running session saw it — a plan survives the store round trip by
/// construction, like everything else in the log.
///
/// The three surfaces, split the brief's way:
/// - **model-written** — the `update_plan` tool (executor on the loop);
/// - **model-read** — the `<current-plan>` section in `onPrompt`;
/// - **user-typed** — the `/plan` command, published through
///   [Commands] and told through the [Terminal], like `/mode`.
///
/// Approval is a human gate, not a tool-permission decision: the agent
/// moves the plan to `requested`; the user answers through the same
/// [Approver] seam the sandbox's file asks use. Nothing wired means the
/// old engine's park: the plan stays `requested`, the section says so,
/// and `/plan approve|reject` answers it later. The plugin never blocks
/// a turn — waiting is the caller's (the executor's) business.
library;

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart';

import 'plugins.dart' show MountsTools;


/// Which item states the schema and the section spell.
const _states = ['pending', 'in_progress', 'done'];

/// The item and text caps, shared by the tool's schema and the store's
/// validation — one vocabulary, both directions.
const planMaxItems = 64;
const planMaxTextLength = 240;

/// The plan state as the plugin holds it between entries: the entry list
/// replayed. The log is the truth; this is the running session's reading
/// of it, kept current by subscribing to the loop.
class PlanState {
  final List<PlanEntryItem> items;
  final PlanApproval approval;

  PlanState({required this.items, this.approval = PlanApproval.none});

  bool get isEmpty => items.isEmpty;

  bool get needsApproval => approval == PlanApproval.requested;

  bool get isApproved => approval == PlanApproval.approved;

  /// The in-progress texts, in order (at most one when validated).
  List<String> get inProgress => [
        for (final i in items) ...[
          if (i.state == 'in_progress') i.text,
          ...[
            for (final c in i.children)
              if (c.state == 'in_progress') c.text,
          ],
        ],
      ];

  /// True when the item *content* matches [other] — same count, same
  /// trimmed text and children in the same order, states ignored. The
  /// edit-resets-approval rule's test: a progress tick preserves an
  /// approval, a re-write clears it.
  bool contentMatches(List<PlanEntryItem> other) {
    if (items.length != other.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (!_itemContentEquals(items[i], other[i])) return false;
    }
    return true;
  }

  static bool _itemContentEquals(PlanEntryItem a, PlanEntryItem b) {
    if (a.text.trim() != b.text.trim()) return false;
    if (a.children.length != b.children.length) return false;
    for (var i = 0; i < a.children.length; i++) {
      if (!_itemContentEquals(a.children[i], b.children[i])) return false;
    }
    return true;
  }
}

/// One plan for one session, held by the plugin. The log carries the
/// durable truth; this cell is the plugin's view of the latest entry,
/// updated by its own log listener. Not conversation-scoped: one host is
/// one session in this engine.
class PlanStore {
  PlanState _state = PlanState(items: const []);

  /// The plan now. Empty when the session carries none.
  PlanState get state => _state;

  /// Fire the plugin's own listener by hand is never needed — the loop's
  /// log is the broadcast. This stream serves surfaces that want to
  /// repaint on a plan change without subscribing to raw entries.
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  /// Replace the plan wholesale. Validates exactly what the entry can
  /// carry: the caps, non-empty trimmed text, the state vocabulary, one
  /// nesting level, at most one in-progress item across the whole plan.
  /// Throws [ArgumentError] on violations so a malformed model call
  /// surfaces as a tool error, not a broken log.
  ///
  /// Approval: an update that changes item *content* resets
  /// [PlanApproval.none] (an edited plan must be re-approved); a
  /// state-only update preserves the current approval unless [approval]
  /// names a new one.
  void update(
    AgentLoop loop,
    List<PlanEntryItem> items, {
    PlanApproval approval = PlanApproval.none,
  }) {
    if (items.length > planMaxItems) {
      throw ArgumentError('plan exceeds $planMaxItems items');
    }
    void validate(PlanEntryItem item, {required bool isChild}) {
      final text = item.text.trim();
      if (text.isEmpty) {
        throw ArgumentError('plan items must have non-empty text');
      }
      if (text.length > planMaxTextLength) {
        throw ArgumentError(
            'plan item text exceeds $planMaxTextLength chars');
      }
      if (!PlanEntryItem.stateWords.contains(item.state)) {
        throw ArgumentError(
            'plan item state must be one of ${_states.join(", ")}');
      }
      if (isChild && item.children.isNotEmpty) {
        throw ArgumentError('plan supports one nesting level only');
      }
      for (final child in item.children) {
        validate(child, isChild: true);
      }
    }

    for (final item in items) {
      validate(item, isChild: false);
    }
    final inProgress = [
      for (final item in items) ...[item, ...item.children],
    ].where((i) => i.state == 'in_progress');
    if (inProgress.length > 1) {
      throw ArgumentError('at most one plan item may be in progress');
    }
    final previous = _state;
    final effective = approval != PlanApproval.none
        ? approval
        : (previous.contentMatches(items)
            ? previous.approval
            : PlanApproval.none);
    _write(loop, items, effective);
  }

  /// The agent asks for sign-off. No-op on an empty plan.
  void requestApproval(AgentLoop loop) =>
      _setApproval(loop, PlanApproval.requested);

  /// The user signs off.
  void approve(AgentLoop loop) => _setApproval(loop, PlanApproval.approved);

  /// The user declines.
  void reject(AgentLoop loop) => _setApproval(loop, PlanApproval.rejected);

  void _setApproval(AgentLoop loop, PlanApproval value) {
    if (_state.isEmpty) {
      throw StateError('no plan to approve');
    }
    if (_state.approval != value) {
      _write(loop, _state.items, value);
    }
  }

  void _write(
      AgentLoop loop, List<PlanEntryItem> items, PlanApproval approval) {
    loop.recordState(PlanChangedEntry(
      items: List.of(items),
      approval: approval,
    ));
    _state = PlanState(items: List.of(items), approval: approval);
    _changes.add(null);
  }

  /// Replay from the loop's log — the startup and resume path. The
  /// listener wired in [PlansPlugin.mountOn] does this once; surfaces
  /// reading [state] before that see an empty plan.
  void hydrateFrom(List<SessionEntry> log) {
    PlanChangedEntry? latest;
    for (final e in log) {
      if (e is PlanChangedEntry) latest = e;
    }
    _state = latest == null
        ? PlanState(items: const [])
        : PlanState(items: List.of(latest.items), approval: latest.approval);
  }

  void dispose() {
    _changes.close();
  }
}

/// Renders the model-facing section: the state rule, the approval
/// posture, the item list. Returns '' for an empty plan — a section that
/// says "there is no plan" is noise, and the join drops empties.
String planSection(PlanState plan) {
  if (plan.isEmpty) return '';
  final buffer = StringBuffer(
    '<current-plan>\n'
    'This conversation maintains a task plan with the update_plan tool.\n'
    'Keep exactly one item in_progress; move items to done only when their '
    'work is finished; call update_plan whenever the plan changes.\n',
  );
  buffer.writeln(switch (plan.approval) {
    PlanApproval.none => 'Approval has not been requested for this plan.',
    PlanApproval.requested =>
      'You asked the user to approve this plan and they have not answered '
          'yet: wait for their approval before doing the planned work.',
    PlanApproval.approved => 'The user approved this plan: proceed.',
    PlanApproval.rejected =>
      'The user rejected this plan: revise it (update_plan replaces the '
          'plan and clears approval), then ask again.',
  });
  String box(String state) => switch (state) {
        'in_progress' => '[~]',
        'done' => '[x]',
        _ => '[ ]',
      };
  for (final item in plan.items) {
    buffer.writeln('${box(item.state)} ${item.text}');
    for (final child in item.children) {
      buffer.writeln('  ${box(child.state)} ${child.text}');
    }
  }
  buffer.writeln('</current-plan>');
  return buffer.toString();
}

/// The plugin: owns the tool, the section and the command; mounts the
/// executor; keeps [store] current by listening to the log.
final class PlansPlugin extends AgentPlugin implements MountsTools {
  PlansPlugin({
    this.id = 'plans',
    this.order = 20,
    Services? services,
    this.approver,
  })  : services = services;

  @override
  final String id;

  /// After the tools plugin (order 10), before compaction (900).
  @override
  final int order;

  /// The session's shared services. May be null for a bare engine test:
  /// without it there is no `/plan` command and no ask — the tool and
  /// the section still work, which is the whole surface the model sees.
  final Services? services;

  /// The ask a `requested` plan is put to. The same seam the sandbox's
  /// file asks use; a host with a dialog wires it, a headless run leaves
  /// it null — the old park, answerable later by `/plan`.
  final Approver? approver;

  final PlanStore store = PlanStore();

  bool _published = false;
  AgentLoop? _loop;

  /// The `update_plan` schema, as the model sees it. The shape follows
  /// the entry: the complete item list each call, one nesting level, the
  /// approval dimension on the side.
  ToolSchema get schema => ToolSchema(
        name: 'update_plan',
        description:
            'Replace this conversation\'s task plan. Pass the complete '
            'item list with each item\'s state (pending, in_progress, '
            'done). An item may carry a flat `children` list of subtask '
            'items (one nesting level; children must not have children). '
            'Keep at most one item in_progress across the whole plan '
            '(children included). Use it to track multi-step work for '
            'the user; call it again whenever the plan changes. Pass '
            'approval: "requested" to ask the user to approve the plan '
            'before you execute it — they approve or reject via /plan, '
            'and the plan you see in context tells you the outcome. You '
            'may also call it with only approval: "requested" to '
            '(re-)request approval for the unchanged plan.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'approval': {
              'type': 'string',
              'enum': ['requested', 'none'],
              'description':
                  '"requested" asks the user to approve this plan before '
                  'work starts. Editing item content clears approval '
                  'again.',
            },
            'items': {
              'type': 'array',
              'maxItems': planMaxItems,
              'items': _itemSchema(allowChildren: true),
            },
          },
          'required': ['items'],
        },
      );

  static Map<String, dynamic> _itemSchema({required bool allowChildren}) => {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'state': {
            'type': 'string',
            'enum': _states,
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
  List<ToolSchema> get tools => [schema];

  @override
  void onPrompt(TurnContext c) {
    final section = planSection(store.state);
    if (section.isNotEmpty) c.promptSections.add(section);
  }

  /// Mount the executor and replay the log into [store]. Idempotent
  /// against double-mount: a second mount re-wires nothing.
  @override
  void mountOn(AgentLoop loop) {
    if (_loop != null) return;
    _loop = loop;
    store.hydrateFrom(loop.log);
    loop.registerExecutor('update_plan', execute);
    loop.subscribe((entry, event) {
      if (entry is PlanChangedEntry) {
        store._state =
            PlanState(items: List.of(entry.items), approval: entry.approval);
        store._changes.add(null);
      }
    });
  }

  /// The tool's write path. All validation errors surface as tool
  /// errors — the model reads the reason and corrects the call; nothing
  /// here throws past the executor boundary.
  Future<ToolResult> execute(Map<String, Object?> input) async {
    final loop = _loop;
    if (loop == null) {
      return ToolResult.error('update_plan is not mounted');
    }
    final approval = switch (input['approval']) {
      null || 'none' => PlanApproval.none,
      'requested' => PlanApproval.requested,
      _ => null,
    };
    if (approval == null) {
      return ToolResult.error('update_plan approval must be "requested" '
          'or "none"');
    }
    final rawItems = input['items'];
    // Approval-only call: re-request on the unchanged plan, no items
    // needed.
    if (rawItems == null) {
      if (approval != PlanApproval.requested) {
        return ToolResult.error(
            'update_plan requires an items array (or approval: '
            '"requested")');
      }
      try {
        store.requestApproval(loop);
      } on StateError {
        return ToolResult.error('no plan to approve');
      }
      return _awaitApprovalIfNeeded();
    }
    if (rawItems is! List) {
      return ToolResult.error('update_plan requires an items array');
    }
    final items = <PlanEntryItem>[];
    try {
      for (final raw in rawItems) {
        items.add(_decodeItem(raw, allowChildren: true));
      }
      store.update(loop, items, approval: approval);
    } on ArgumentError catch (error) {
      return ToolResult.error(error.message?.toString() ?? 'invalid plan');
    }
    if (store.state.approval == PlanApproval.requested) {
      return _awaitApprovalIfNeeded();
    }
    return switch (store.state.approval) {
      PlanApproval.approved => ToolResult('Plan updated; approved.'),
      _ => ToolResult('Plan updated.'),
    };
  }

  /// A `requested` plan is put to the wired [approver] — the same
  /// seam the sandbox's file asks use, so the answer rides the host's
  /// real dialog. Nothing wired means the old park: the plan stays
  /// `requested`, the section tells the model to wait, `/plan
  /// approve|reject` answers later. The tool result names the outcome
  /// either way; it never blocks the turn silently.
  Future<ToolResult> _awaitApprovalIfNeeded() async {
    final asker = approver;
    if (asker == null) {
      return ToolResult(
          'Plan updated; waiting for user approval (they will answer '
          'via /plan; the plan in your context tells you the outcome).');
    }
    final plan = store.state;
    final reason = plan.items.map((i) => '[ ] ${i.text}').join('\n');
    final answer = await asker(
      (op: FileOp.write, path: 'plan://approval'),
      'approve this plan?\n$reason',
    );
    final loop = _loop!;
    return switch (answer) {
      Approval.yes || Approval.always => () {
          store.approve(loop);
          return ToolResult('Plan updated; approved by the user.');
        }(),
      Approval.no => () {
          store.reject(loop);
          return ToolResult(
              'Plan updated; the user rejected it: revise the plan '
              '(update_plan replaces it and clears approval), then ask '
              'again.');
        }(),
    };
  }

  /// Decode one model-supplied item. Missing or junk text/state is an
  /// [ArgumentError] (a tool error); children of children are rejected,
  /// not flattened.
  static PlanEntryItem _decodeItem(dynamic raw,
      {required bool allowChildren}) {
    final text = switch (raw) {
      {'text': String text} => text,
      _ => throw ArgumentError('plan item requires string text'),
    };
    final state = switch (raw) {
      {'state': 'pending'} => 'pending',
      {'state': 'in_progress'} => 'in_progress',
      {'state': 'done'} => 'done',
      _ => throw ArgumentError(
          'plan item state must be pending, in_progress or done'),
    };
    final children = <PlanEntryItem>[];
    final rawChildren = switch (raw) {
      {'children': final List rawChildren} => rawChildren,
      {'children': _} => throw ArgumentError(
          'plan item children must be an array'),
      _ => const <dynamic>[],
    };
    if (rawChildren.isNotEmpty && !allowChildren) {
      throw ArgumentError(
          'plan supports one nesting level only (children of children)');
    }
    for (final rawChild in rawChildren) {
      children.add(_decodeItem(rawChild, allowChildren: false));
    }
    return PlanEntryItem(text, state: state, children: children);
  }

  /// The user's surface: `/plan` — show, toggle, edit, and answer an
  /// approval. Published into the shared [Commands] registry; told
  /// through the [Terminal]. No services, no command.
  void register() {
    final locator = services;
    if (locator == null || _published) return;
    locator.get<Commands>().publish(Command(
          name: 'plan',
          description:
              'show or edit the plan (approve/reject when the agent '
              'asks for sign-off)',
          handler: _planCommand,
        ));
    _published = true;
  }

  void _planCommand(String argument) {
    final loop = _loop;
    final terminal = services!.get<Terminal>();
    final args = argument.trim();
    if (args.isEmpty) {
      _showPlan(terminal);
      return;
    }
    if (RegExp(r'^clear$', caseSensitive: false).hasMatch(args)) {
      if (loop == null) return;
      store.update(loop, const []);
      terminal.writeln('Plan cleared.');
      return;
    }
    final approvalOp = RegExp(r'^(approve|reject|request-approval)$',
            caseSensitive: false)
        .firstMatch(args);
    if (approvalOp != null) {
      if (loop == null) return;
      try {
        switch (approvalOp.group(1)!.toLowerCase()) {
          case 'approve':
            store.approve(loop);
          case 'reject':
            store.reject(loop);
          case 'request-approval':
            store.requestApproval(loop);
        }
      } on StateError {
        terminal.writeln('No plan to ${approvalOp.group(1)!}.');
        return;
      }
      _showPlan(terminal);
      return;
    }
    final toggle =
        RegExp(r'^(done|pending)\s+(\d+)$', caseSensitive: false)
            .firstMatch(args);
    if (toggle != null) {
      if (loop == null) return;
      final index = int.parse(toggle.group(2)!) - 1;
      final items = store.state.items;
      if (index < 0 || index >= items.length) {
        terminal.writeln('No plan item ${index + 1}.');
        return;
      }
      try {
        store.update(loop, [
          for (final (i, item) in items.indexed)
            i == index
                ? item.copyWith(
                    state:
                        toggle.group(1)!.toLowerCase() == 'done'
                            ? 'done'
                            : 'pending')
                : item,
        ]);
      } on ArgumentError catch (error) {
        terminal.writeln('${error.message}');
        return;
      }
      _showPlan(terminal);
      return;
    }
    // Free text falls through as one new pending item — the old
    // command's shorthand for starting a plan mid-session.
    final text = RegExp(r'^add\s+(.+)$', caseSensitive: false)
            .firstMatch(args)
            ?.group(1) ??
        args;
    try {
      store.update(loop!, [
        ...store.state.items,
        PlanEntryItem(text, state: 'pending'),
      ]);
    } on ArgumentError catch (error) {
      terminal.writeln('${error.message}');
      return;
    }
    _showPlan(terminal);
  }

  void _showPlan(Terminal terminal) {
    final plan = store.state;
    if (plan.isEmpty) {
      terminal.writeln(
          'No plan. `/plan add <text>` starts one; the agent maintains '
          'it with update_plan.');
      return;
    }
    final buffer = StringBuffer('Plan:\n');
    if (plan.needsApproval) buffer.writeln('  approval: REQUESTED');
    if (plan.isApproved) buffer.writeln('  approval: approved');
    if (plan.approval == PlanApproval.rejected) {
      buffer.writeln('  approval: rejected');
    }
    String box(String state) => switch (state) {
          'in_progress' => '[~]',
          'done' => '[x]',
          _ => '[ ]',
        };
    for (final (i, item) in plan.items.indexed) {
      buffer.writeln('  ${i + 1}. ${box(item.state)} ${item.text}');
      for (final child in item.children) {
        buffer.writeln('      ${box(child.state)} ${child.text}');
      }
    }
    terminal.writeln(buffer.toString());
  }
}
