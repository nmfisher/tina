import 'session_details.dart';
import 'session_log.dart';

/// Facts and explicit lifecycle access supplied to every session plugin.
final class PluginSession {
  PluginSession({
    required this.id,
    required this.workingDirectory,
    this.title,
    this.model,
    this.resuming = false,
    SessionDetails? details,
    required this.notifyChanged,
    this.deliverNotice,
  }) : details = details ?? SessionDetails();

  final String id;
  final String workingDirectory;
  final String? title;
  String? model;
  final bool resuming;
  SessionDetails details;
  final void Function() notifyChanged;

  /// Delivers asynchronous text into this session's transcript as a new
  /// turn (or, mid-turn, as queued steering input) — the seam a plugin
  /// uses to hand the model a result that arrived outside any turn, such
  /// as a background job's output or a spawned child's answer. The host
  /// supplies the implementation; null means the application does not
  /// support injection and the plugin keeps its results pollable instead.
  final void Function(String text)? deliverNotice;
}

/// Restored session state. The host seeds the loop; plugins never append to
/// a second transcript or write directly to the loop's log.
final class SessionSeed {
  SessionSeed({required this.log, required this.details, this.model});
  final List<SessionEntry> log;
  final SessionDetails details;
  final String? model;
}
