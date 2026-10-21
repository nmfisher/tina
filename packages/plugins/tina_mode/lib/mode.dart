/// Session permission policy. The UI and command share this vocabulary.
enum PermissionMode {
  ask,
  readOnly,
  allowEdits,
  auto,
  /// Start-time only: disables every permission/approval check. Reachable
  /// solely via `tina --yolo`; never selectable through `/mode`.
  yolo;

  String get label => switch (this) {
    ask => 'ask',
    readOnly => 'read-only',
    allowEdits => 'allow-edits',
    auto => 'auto',
    yolo => 'yolo',
  };

  /// The next user-selectable mode. yolo is start-time only and is skipped
  /// so the cycle never lands on it.
  PermissionMode get next {
    var i = (index + 1) % values.length;
    while (values[i] == PermissionMode.yolo) {
      i = (i + 1) % values.length;
    }
    return values[i];
  }
}

abstract interface class ModeControl {
  PermissionMode get mode;
  set mode(PermissionMode value);
}
