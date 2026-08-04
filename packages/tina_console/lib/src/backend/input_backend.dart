import '../input_event.dart';

/// Abstract interface for terminal input sources.
///
/// Decouples [LineEditor] from the raw byte stream. The ANSI backend wraps
/// [Stdio.stdin] through [InputParser]; the notcurses backend wraps native
/// key events from the notcurses event loop.
abstract class InputBackend {
  /// Completes when startup filtering is finished and interactive input can be
  /// shown without losing terminal capability replies.
  Future<void> get ready;

  /// A stream of semantic input events.
  Stream<InputEvent> get events;

  /// Push [event] directly onto [events] as if it had arrived from the
  /// terminal. Used by signal handlers and menu callbacks that synthesize
  /// key events (e.g. SIGINT delivers `ControlKey(ControlCode.ctrlC)`).
  void inject(InputEvent event);

  /// Release any subscriptions / timers / native resources.
  void dispose();
}
