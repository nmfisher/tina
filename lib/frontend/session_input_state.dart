/// Drafts and Escape arming belong to the frontend, not turn admission.
class SessionInputState {
  final drafts = <String, ({String buffer, int cursor})>{};
  bool cancelArmed = false;
  void resetEscape() => cancelArmed = false;
}
