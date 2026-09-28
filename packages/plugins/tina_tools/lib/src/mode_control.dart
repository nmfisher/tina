library;

import 'permissions.dart' show PermissionMode;

/// Read and set the session's permission mode.
abstract interface class ModeControl {
  /// The mode as of now.
  PermissionMode get mode;

  /// Switch the mode. The next tool call obeys it — the boundary reads
  /// the value per call; nothing else changes.
  set mode(PermissionMode value);
}
