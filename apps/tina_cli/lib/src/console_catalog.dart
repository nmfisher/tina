import 'package:classification/plugin.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_classification_tui/tina_classification_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_activity/tina_activity.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_mcp_tui/tina_mcp_tui.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_plans_tui/tina_plans_tui.dart';

/// Presentation factories are separate from runtime plugin construction. Each
/// call creates a view for one attachment to the existing feature instance.
final _viewFactories =
    <String, ConsoleContribution? Function(AgentPlugin, ClientAccess)>{
  'tina/approvals-tui': (plugin, access) => ApprovalView(
      (plugin as AttachmentApprovalChannel).interaction.forClient(access)),
  'tina/mode': (plugin, access) => ModeView(
      mode: (plugin as PresentationPlugin<ModeObservation>)
          .source
          .forClient(access)),
  'tina/context-tui': (plugin, access) => ContextView(
      context: (plugin as PresentationPlugin<ContextObservation>).source),
  'tina/update-tui': (plugin, access) => UpdateView(
      _ClientUpdateStatus(
          (plugin as PresentationPlugin<UpdateStatusSource>).source, access),
      checkOnAttach: access.canControl),
  'tina/status-strip-tui': (_, access) => StatusStripView(),
  'tina/panels-tui': (_, access) => PanelsView(),
  'tina/chat-tui': (plugin, access) =>
      ChatView((plugin as ChatPlugin).observation),
  'tina/activity-tui': (plugin, access) => ActivityView(
      (plugin as ActivityPlugin).observation,
      printTranscript: plugin.printTranscript),
  'tina/session-controls': (plugin, access) => SessionControlsView(
      (plugin as SessionControlsPlugin).observation.forClient(access)),
  'tina/plans': (plugin, access) =>
      PlansView((plugin as PlansPlugin).observation),
  'tina/classification': (plugin, access) =>
      ClassificationView((plugin as ClassificationPlugin).observation),
  'tina/mcp': (plugin, access) {
    final management = (plugin as McpPlugin).management;
    return management == null ? null : McpView(management.forClient(access));
  },
};

/// Existing extensions may still supply a combined contribution. All built-in
/// presentation is constructed through the factories above.
ConsoleContribution? createConsoleView(AgentPlugin plugin,
    {ClientAccess access = const ClientAccess()}) {
  final factory = _viewFactories[plugin.id];
  if (factory != null) return factory(plugin, access);
  // Combined extensions have no checked client contract. An observer must
  // never receive their unrestricted runtime callbacks.
  if (!access.canControl) return null;
  return plugin is ConsoleContribution ? plugin as ConsoleContribution : null;
}

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
