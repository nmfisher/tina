import 'package:tina_engine_2/tina_engine_2.dart';

/// Read-only chat presentation data, independent of the runtime plugin.
abstract interface class ChatObservation {
  SessionObservation get events;
  String get model;
  String? get sessionId;
  int get tokenCap;
  int? get sessionTokens;
  int get sessionEstimatedTokens;
  bool get showSessionId;
  bool get terminalAlertsEnabled;
}
