/// Session permission policy. The UI and command share this vocabulary.
enum PermissionMode {
  ask,
  readOnly,
  allowEdits,
  auto;

  String get label => switch (this) {
    ask => 'ask',
    readOnly => 'read-only',
    allowEdits => 'allow-edits',
    auto => 'auto',
  };

  PermissionMode get next => values[(index + 1) % values.length];
}

abstract interface class ModeControl {
  PermissionMode get mode;
  set mode(PermissionMode value);
}
