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
final _viewFactories = <String, ConsoleContribution? Function(AgentPlugin)>{
  'tina/approvals-tui': (plugin) =>
      ApprovalView((plugin as AttachmentApprovalChannel).interaction),
  'tina/mode': (plugin) =>
      ModeView(mode: (plugin as PresentationPlugin<ModeObservation>).source),
  'tina/context-tui': (plugin) => ContextView(
      context: (plugin as PresentationPlugin<ContextObservation>).source),
  'tina/update-tui': (plugin) =>
      UpdateView((plugin as PresentationPlugin<UpdateStatusSource>).source),
  'tina/status-strip-tui': (_) => StatusStripView(),
  'tina/panels-tui': (_) => PanelsView(),
  'tina/chat-tui': (plugin) => ChatView((plugin as ChatPlugin).observation),
  'tina/activity-tui': (plugin) => ActivityView(
      (plugin as ActivityPlugin).observation,
      printTranscript: plugin.printTranscript),
  'tina/session-controls': (plugin) =>
      SessionControlsView((plugin as SessionControlsPlugin).observation),
  'tina/plans': (plugin) => PlansView((plugin as PlansPlugin).observation),
  'tina/classification': (plugin) =>
      ClassificationView((plugin as ClassificationPlugin).observation),
  'tina/mcp': (plugin) {
    final management = (plugin as McpPlugin).management;
    return management == null ? null : McpView(management);
  },
};

/// Existing extensions may still supply a combined contribution. All built-in
/// presentation is constructed through the factories above.
ConsoleContribution? createConsoleView(AgentPlugin plugin) {
  final factory = _viewFactories[plugin.id];
  if (factory != null) return factory(plugin);
  return plugin is ConsoleContribution ? plugin as ConsoleContribution : null;
}
