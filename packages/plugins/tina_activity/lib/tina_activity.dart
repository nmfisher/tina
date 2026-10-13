import 'package:tina_engine_2/tina_engine_2.dart';

/// Session observation lifetime is independent of the activity browser.
final class ActivityPlugin extends AgentPlugin {
  ActivityPlugin({required this.terminal, this.printTranscript = true});
  final Terminal terminal;
  final bool printTranscript;
  final _source = SessionObservationSource();
  SessionObservation get observation => _source.observation;
  Map<String, Object?> historyMetadata(SessionEntry entry) =>
      _source.historyMetadata(entry);
  @override
  String get id => 'tina/activity-tui';
  @override
  List<Command> get commands => [
    Command(
      name: 'activity',
      description: 'browse tool results, diffs and child progress (F4)',
      handler: (_) =>
          terminal.writeln('Activity requires the interactive console.'),
    ),
  ];
  @override
  void mountOn(AgentLoop loop) => _source.mountOn(loop);
  @override
  void closeSession() => _source.close();
}
