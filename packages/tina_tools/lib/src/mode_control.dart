/// The mode as a service: read the mode, set the mode.
///
/// Defined here because the enum lives here — the permission vocabulary
/// and the door to it stay in one package. The one implementor is the
/// enforcement boundary itself ([SandboxedFileSystem] already carries
/// the value and reads it per call): the brief's "ToolsPlugin registers
/// itself under `ModeControl`" is literal — the object registered under
/// this type *is* the plugin that owns the tools, not a copy of the
/// value and not a second authority. Who may flip the mode is decided by
/// whoever builds the session; they hand the locator out only to code
/// meant to have it. A caller without the locator cannot even ask.
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
