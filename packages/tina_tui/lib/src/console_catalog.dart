import 'package:classification/plugin.dart';
import 'package:tina_classification_tui/tina_classification_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_plans_tui/tina_plans_tui.dart';

/// Presentation factories are separate from runtime plugin construction. Each
/// call creates a view for one attachment to the existing feature instance.
final _viewFactories = <String, ConsoleContribution Function(AgentPlugin)>{
  'tina/plans': (plugin) => PlansView((plugin as PlansPlugin).observation),
  'tina/classification': (plugin) =>
      ClassificationView((plugin as ClassificationPlugin).observation),
};

/// Features not yet split, including existing extensions, retain their console
/// contribution until their presentation factories migrate here.
ConsoleContribution? createConsoleView(AgentPlugin plugin) {
  final factory = _viewFactories[plugin.id];
  if (factory != null) return factory(plugin);
  return plugin is ConsoleContribution ? plugin as ConsoleContribution : null;
}
