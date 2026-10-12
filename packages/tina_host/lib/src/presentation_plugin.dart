import 'package:tina_engine_2/tina_engine_2.dart';

/// Runtime declaration for a frontend-only feature. The catalog owns its ID,
/// dependencies and headless command behavior; attachments own all view state.
/// [source] is a feature capability, never a terminal or view instance.
final class PresentationPlugin<T> extends AgentPlugin {
  PresentationPlugin(
      {required this.id,
      required this.source,
      this.order = 100,
      List<Command> commands = const []})
      : commands = List.unmodifiable(commands);
  @override
  final String id;
  final T source;
  @override
  final int order;
  @override
  final List<Command> commands;
}
