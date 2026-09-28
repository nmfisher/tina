import 'session_details.dart';
import 'session_log.dart';

/// Facts and explicit lifecycle access supplied to every session plugin.
final class PluginSession {
  PluginSession({
    required this.id,
    required this.workingDirectory,
    this.title,
    this.resuming = false,
    SessionDetails? details,
    required this.notifyChanged,
  }) : details = details ?? SessionDetails();

  final String id;
  final String workingDirectory;
  final String? title;
  final bool resuming;
  SessionDetails details;
  final void Function() notifyChanged;
}

/// Restored session state. The host seeds the loop; plugins never append to
/// a second transcript or write directly to the loop's log.
final class SessionSeed {
  SessionSeed({required this.log, required this.details});
  final List<SessionEntry> log;
  final SessionDetails details;
}
