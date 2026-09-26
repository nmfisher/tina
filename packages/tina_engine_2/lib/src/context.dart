/// The one cancellation path a plugin holds. That is all [Context] is.
library;

/// The one cancellation path. Set once; there is no unset. The loop checks
/// it before every model call and before every tool.
final class CancelToken {
  bool cancelled = false;
  String reason = '';

  /// First cancel wins. Later calls change nothing.
  void cancel(String why) {
    if (cancelled) return;
    cancelled = true;
    reason = why;
  }
}

/// What a hook run hands the plugin: the cancel path, nothing else.
/// A plugin acts by returning values from its hooks; it never reads
/// state through this object.
final class Context {
  Context(this._cancel);

  final CancelToken _cancel;

  /// Mark the turn cancelled. First call wins.
  void cancel(String why) => _cancel.cancel(why);
}
