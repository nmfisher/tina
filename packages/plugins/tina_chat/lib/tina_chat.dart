export 'settings.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// One observer per session; transcript rendering belongs to attachments.
final class ChatPlugin extends AgentPlugin implements WatchObserver {
  ChatPlugin({
    required this.model,
    this.tokenCap = 0,
    this.currentTokenCap,
    this.sessionTokens,
    this.sessionEstimatedTokens,
    this.showSessionId = true,
    this.terminalAlertsEnabled,
  });
  final String model;
  final int tokenCap;
  final int Function()? currentTokenCap, sessionTokens, sessionEstimatedTokens;
  final bool showSessionId;
  final bool Function()? terminalAlertsEnabled;
  final _source = SessionObservationSource();
  String? _sessionId;
  late final observation = ChatObservation._(this);
  @override
  String get id => 'tina/chat-tui';
  @override
  SessionSeed? openSession(PluginSession session) {
    _sessionId = session.id;
    return null;
  }

  @override
  void mountOn(AgentLoop loop) => _source.mountOn(loop);
  @override
  void watch(WatchEvent event) => _source.watch(event);
  @override
  void closeSession() => _source.close();
}

final class ChatObservation {
  ChatObservation._(this._plugin);
  final ChatPlugin _plugin;
  SessionObservation get events => _plugin._source.observation;
  String get model => events.model ?? _plugin.model;
  String? get sessionId => _plugin._sessionId;
  int get tokenCap => _plugin.currentTokenCap?.call() ?? _plugin.tokenCap;
  int? get sessionTokens => _plugin.sessionTokens?.call();
  int get sessionEstimatedTokens => _plugin.sessionEstimatedTokens?.call() ?? 0;
  bool get showSessionId => _plugin.showSessionId;
  bool get terminalAlertsEnabled =>
      _plugin.terminalAlertsEnabled?.call() ?? true;
}
