/// The permission vocabulary for tina_tools.
///
/// The architecture (Nick's call): **no tool declares what it is allowed to
/// do.** The model is free to try any tool; the thing that refuses is the
/// [SandboxedFileSystem] the tool was handed, and the refusal comes back to
/// the model as that call's tool result. This file survives from the
/// declaration-based design because the enforcement boundary needs the same
/// two words: what was decided ([ToolVerdict]) and under which session mode
/// ([PermissionMode]).
///
/// The rule that outlived the declarations: **read-only never asks** — a
/// write in `readOnly` mode is denied outright, never put to the user.
library;

/// What was decided about one operation.
///
/// An [ToolVerdict.ask] is *not* an answer: whoever resolves it — the
/// filesystem's asker — decides, and no asker wired means deny.
enum ToolVerdict {
  /// Perform the operation.
  allow,

  /// Refuse it; the reason reaches the model as the tool result.
  deny,

  /// The asker decides. With no asker, this resolves to deny — fail closed.
  ask,
}

/// Session-wide permission mode.
///
/// Only two. The operation × mode table is decided by the filesystem per
/// call: in [PermissionMode.normal] reads run, writes inside the project
/// root run, writes outside it ask; in [PermissionMode.readOnly] reads run
/// and every write is denied — and never put to the user.
enum PermissionMode {
  /// Reads and in-project writes run; out-of-project writes ask.
  normal,

  /// Reads run; every write is denied without asking anyone.
  readOnly,
}
