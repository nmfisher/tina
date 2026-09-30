import 'package:tina_engine_2/tina_engine_2.dart';

final class SessionWorkflowRun {
  /// How the run ended, as [WorkflowRunEntry] spells it.
  final String status;

  /// The workflow's name — the catalog name it launched under.
  final String workflow;

  /// The run's final output: the last node's response on success, the
  /// failure reason otherwise. Empty when the run produced neither.
  final String detail;

  /// The node ids that executed, in execution order.
  final List<String> nodes;

  const SessionWorkflowRun({
    required this.workflow,
    required this.status,
    this.detail = '',
    this.nodes = const [],
  });

  bool get isSuccess => status == WorkflowRunEntry.statusSuccess;

  @override
  bool operator ==(Object other) =>
      other is SessionWorkflowRun &&
      workflow == other.workflow &&
      status == other.status &&
      detail == other.detail &&
      _stringListEquals(nodes, other.nodes);

  @override
  int get hashCode =>
      Object.hash(workflow, status, detail, Object.hashAll(nodes));

  @override
  String toString() =>
      'SessionWorkflowRun($workflow, $status, ${nodes.length} nodes)';
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One workflow run ended. The run itself is not part of the
/// conversation — a node's work is real turns in the log, and that is
/// where its content lives — but the run's **outcome** is a whole-state
/// fact no later log reading can recompute (which graph traversal
/// produced these turns, and how the traversal ended). Like
/// [PlanChangedEntry] and [GoalChangedEntry], the entry **is** the
/// state: the latest one wins in a derive, so a resume sees the same
/// last-run summary the running session did.
///
/// The node list is an audit trail, capped by the writer; a run that
/// failed before any node executed records an empty list.
final class WorkflowRunEntry extends PluginStateEntry {
  static bool matches(SessionEntry entry) =>
      entry is PluginStateEntry &&
      entry.pluginId == 'tina/workflows' &&
      entry.stateKey == 'last-run';
  static WorkflowRunEntry decode(PluginStateEntry entry) {
    if (!matches(entry) || entry.schemaVersion != 1)
      throw FormatException(
          'Unsupported tina/workflows state version ${entry.schemaVersion}');
    return fromJson(entry.value ?? {'workflow': 'cleared', 'status': 'success'},
        entry.at, entry.seq);
  }

  static const kindName = 'workflow_run';

  /// The only status words an entry carries.
  static const statusSuccess = 'success';
  static const statusFailed = 'failed';

  /// The workflow's name — the catalog name it launched under.
  final String workflow;

  /// How the run ended: [statusSuccess] or [statusFailed].
  final String status;

  /// The run's final output: the last node's response on success, the
  /// failure reason otherwise.
  final String detail;

  /// The node ids that executed, in execution order.
  final List<String> nodes;

  final String at;

  const WorkflowRunEntry({
    required this.workflow,
    required this.status,
    this.detail = '',
    this.nodes = const [],
    this.at = '',
    super.seq = 0,
  });

  /// The writer's constructor: validates the status word and rejects an
  /// empty workflow name, so a bad append throws at the writer instead
  /// of decoding into a run nobody launched.
  factory WorkflowRunEntry.record({
    required String workflow,
    required String status,
    String detail = '',
    List<String> nodes = const [],
    String at = '',
  }) {
    if (workflow.isEmpty) {
      throw const FormatException('workflow_run requires a workflow name');
    }
    if (status != statusSuccess && status != statusFailed) {
      throw FormatException(
          'workflow_run status must be "$statusSuccess" or "$statusFailed"');
    }
    return WorkflowRunEntry(
      workflow: workflow,
      status: status,
      detail: detail,
      nodes: List.of(nodes),
      at: at,
    );
  }

  @override
  WorkflowRunEntry withSeq(int newSeq) => WorkflowRunEntry(
        workflow: workflow,
        status: status,
        detail: detail,
        nodes: nodes,
        at: at,
        seq: newSeq,
      );

  @override
  String get pluginId => 'tina/workflows';
  @override
  String get stateKey => 'last-run';
  @override
  int get schemaVersion => 1;

  @override
  Map<String, dynamic> get value => {
        'workflow': workflow,
        'status': status,
        'detail': detail,
        'nodes': [...nodes],
      };

  /// Strict decode: the status word is validated (a corrupt row is a
  /// reader error, not a successful run) and the workflow name must be
  /// there. The node cap matches the writer's — see the plugin.
  static WorkflowRunEntry fromJson(
    Map<String, dynamic> j,
    String at,
    int seq,
  ) {
    final workflow = j['workflow'];
    final status = j['status'];
    if (workflow is! String || workflow.isEmpty) {
      throw const FormatException('workflow_run requires a workflow name');
    }
    if (status != statusSuccess && status != statusFailed) {
      throw FormatException(
          'workflow_run status must be "$statusSuccess" or "$statusFailed"');
    }
    final rawNodes = j['nodes'];
    if (rawNodes != null && rawNodes is! List) {
      throw const FormatException('workflow_run nodes must be an array');
    }
    return WorkflowRunEntry(
      workflow: workflow,
      status: status,
      detail: (j['detail'] as String?) ?? '',
      nodes: [
        for (final n in (rawNodes as List?) ?? const []) n as String,
      ],
      at: at,
    ).withSeq(seq);
  }

  @override
  bool operator ==(Object other) =>
      other is WorkflowRunEntry &&
      workflow == other.workflow &&
      status == other.status &&
      detail == other.detail &&
      _stringListEquals(nodes, other.nodes) &&
      at == other.at;

  @override
  int get hashCode =>
      Object.hash(workflow, status, detail, Object.hashAll(nodes), at);

  @override
  String toString() => 'WorkflowRun($workflow, $status, ${nodes.length} nodes)';
}

extension WorkflowsProjection on DerivedSession {
  SessionWorkflowRun? get workflowRun {
    final raw = pluginStates['tina/workflows']?['last-run'];
    if (raw == null || raw.value == null) return null;
    final e = WorkflowRunEntry.decode(raw);
    return SessionWorkflowRun(
        workflow: e.workflow,
        status: e.status,
        detail: e.detail,
        nodes: e.nodes);
  }
}
