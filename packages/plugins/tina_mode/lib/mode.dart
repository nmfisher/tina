/// Session permission policy. The UI and command share this vocabulary.
enum PermissionMode {
  approve,
  // Kept only to decode old embedders/state. Live policies normalize these
  // values to approve; no legacy value grants workspace writes.
  ask,
  readOnly,
  allowEdits,
  auto,

  /// Start-time only: grants capabilities; confirmations still ask. Reachable
  /// solely via `tina --yolo`; never selectable through `/mode`.
  yolo;

  String get label => switch (this) {
    approve => 'approve',
    ask => 'ask',
    readOnly => 'read-only',
    allowEdits => 'allow-edits',
    auto => 'auto',
    yolo => 'yolo',
  };

  /// The next user-selectable mode. yolo is start-time only and is skipped
  /// so the cycle never lands on it.
  PermissionMode get next {
    return this == auto ? approve : auto;
  }

  PermissionMode get normalized => switch (this) {
    auto => auto,
    yolo => yolo,
    _ => approve,
  };
}

abstract interface class ModeControl {
  PermissionMode get mode;
  set mode(PermissionMode value);
}
