import 'mode.dart';
export 'mode.dart';

/// Permission display data. Enforcement and changes belong to the owner.
abstract interface class ModeObservation {
  PermissionMode get mode;
  void Function() listen(void Function(PermissionMode) listener);
}
