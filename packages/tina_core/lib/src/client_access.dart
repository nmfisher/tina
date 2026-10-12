/// Owner-issued authority for an in-process feature client. A client can
/// further restrict this authority, but cannot remove an existing restriction.
/// This is an application boundary, not isolation from arbitrary Dart code.
final class ClientAccess {
  const ClientAccess({bool canControl = true, void Function()? checkActive})
      : _control = canControl,
        _checkActive = checkActive;

  final bool _control;
  final void Function()? _checkActive;

  bool get isActive {
    try {
      _checkActive?.call();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get canControl => _control && isActive;

  void requireControl() {
    _checkActive?.call();
    if (!_control) throw const SessionAccessDenied();
  }

  ClientAccess restrict(ClientAccess other) => ClientAccess(
      canControl: _control && other._control,
      checkActive: () {
        _checkActive?.call();
        other._checkActive?.call();
      });
}

final class SessionAccessDenied implements Exception {
  const SessionAccessDenied();
  @override
  String toString() =>
      'This connection can observe the session but cannot change it.';
}
