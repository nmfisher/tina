import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_classification_tui/tina_classification_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_cwd_tui/tina_cwd_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_mcp_tui/tina_mcp_tui.dart';
import 'package:tina_plans_tui/tina_plans_tui.dart';
import 'package:tina_tasks_tui/tina_tasks_tui.dart';
import 'package:tina_token_rate_tui/tina_token_rate_tui.dart';

/// Application-owned construction of a fresh view for each attachment.
typedef ConsoleViewFactory = ConsoleContribution? Function(AgentPlugin plugin,
    {required SessionConnection connection});

/// Presentation factories are separate from runtime plugin construction. Each
/// call creates a view for one attachment to the existing feature instance.
final _viewFactories =
    <String, ConsoleContribution? Function(AgentPlugin, ClientAccess)>{
  'tina/approvals-tui': (plugin, access) => ApprovalView(
      (plugin as AttachmentApprovalChannel).interaction.forClient(access)),
  'tina/update-tui': (plugin, access) => UpdateView(
      _ClientUpdateStatus(
          (plugin as PresentationPlugin<UpdateStatusSource>).source, access),
      checkOnAttach: access.canControl),
  'tina/status-strip-tui': (_, access) => StatusStripView(),
  'tina/cwd-tui': (plugin, access) =>
      CwdView((plugin as PresentationPlugin<String>).source),
  'tina/panels-tui': (_, access) => PanelsView(),
  'tina/mcp': (plugin, access) {
    final management = (plugin as McpPlugin).management;
    return management == null ? null : McpView(management.forClient(access));
  },
};

/// Only registered factories provide presentation. Runtime-only plugins have
/// no console view; a runtime plugin is never itself used as a view.
ConsoleContribution? createConsoleView(AgentPlugin plugin,
        {required SessionConnection connection}) =>
    switch (plugin.id) {
      'tina/chat-tui' => ChatView(ConnectionChatObservation(connection)),
      'tina/activity-tui' => ActivityView(connection),
      'tina/plans' => PlansView(ConnectionPlanObservation(connection)),
      'tina/classification' =>
        ClassificationView(ConnectionClassificationObservation(connection)),
      'tina/tasks' =>
        TaskOverviewView(ConnectionTaskObservation(connection)),
      'tina/context-tui' =>
        ContextView(context: ConnectionContextObservation(connection)),
      'tina/mode' => ModeView(mode: ConnectionModeObservation(connection)),
      'tina/session-controls' =>
        SessionControlsView(ConnectionSessionControls(connection)),
      'tina/token-rate-tui' =>
        TokenRateGaugeView(ConnectionChatObservation(connection)),
      _ => _viewFactories[plugin.id]?.call(plugin, connection.access),
    };

final class _ClientUpdateStatus implements UpdateStatusSource {
  _ClientUpdateStatus(this._source, this._access);
  final UpdateStatusSource _source;
  final ClientAccess _access;
  @override
  String get currentVersion => _source.currentVersion;
  @override
  UpdateStatus get status => _source.status;
  @override
  Stream<void> get changes => _source.changes;
  @override
  Future<void> checkInBackground() {
    _access.requireControl();
    return _source.checkInBackground();
  }
}
