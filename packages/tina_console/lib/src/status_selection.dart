import 'input_event.dart';
import 'modal_surface.dart';
import 'console_contribution.dart';

/// Shared, per-attachment state for cycling among selectable status segments.
///
/// A status contribution that wants to be reachable by the status-cycling
/// mode registers a segment id with an activation callback. While cycling is
/// active exactly one segment is highlighted; the contributions render their
/// own highlight (typically by styling their `RenderLine` runs with the
/// selection color) by consulting [isHighlighted].
///
/// This object is pure state — it owns no key handling and no rendering. The
/// interaction is driven by [StatusCycleController], which captures navigation
/// keys and translates them into [engage]/[cycle]/[activate]/[cancel] calls.
final class StatusSelection {
  final List<String> _ids = [];
  final Map<String, void Function()> _activate = {};
  bool _active = false;
  String? _highlighted;

  /// Whether cycling mode is currently engaged.
  bool get active => _active;

  /// The highlighted segment id while cycling, or null when idle.
  String? get highlightedId => _highlighted;

  /// Whether at least one segment is registered (so cycling has a target).
  bool get hasSegments => _ids.isNotEmpty;

  /// Whether [id] is the currently-highlighted segment while cycling active.
  bool isHighlighted(String id) => _active && _highlighted == id;

  /// Register a selectable status segment. Call [unregister] on detach.
  void register(String id, void Function() activate) {
    if (!_ids.contains(id)) _ids.add(id);
    _activate[id] = activate;
  }

  /// Remove a segment. If it held the highlight, cycling moves on or stops.
  void unregister(String id) {
    _ids.remove(id);
    _activate.remove(id);
    if (_highlighted == id) _highlighted = _ids.isEmpty ? null : _ids.first;
    if (_active && _ids.isEmpty) _active = false;
  }

  /// Begin cycling: highlight a pool (if any).
  void engage() {
    if (_active || _ids.isEmpty) return;
    _active = true;
    _highlighted ??= _ids.first;
  }

  /// Move the highlight by [dir] (±1), wrapping.
  void cycle(int dir) {
    if (!_active || _ids.isEmpty) return;
    final i = _highlighted == null ? -1 : _ids.indexOf(_highlighted!);
    final next = ((i + dir) % _ids.length + _ids.length) % _ids.length;
    _highlighted = _ids[next];
  }

  /// Commit the highlighted segment. Ends cycling and runs its action.
  /// Returns true if a segment was activated.
  bool activate() {
    if (!_active) return false;
    final id = _highlighted;
    _active = false;
    _highlighted = null;
    if (id == null) return false;
    final cb = _activate[id];
    if (cb == null) return false;
    cb();
    return true;
  }

  /// Leave cycling without activating anything.
  void cancel() {
    _active = false;
    _highlighted = null;
  }
}

/// Drives the status-cycling interaction: an engage binding (F5) that enters
/// a modal mode where Tab/arrows move the highlight and Enter commits the
/// highlighted segment.
///
/// While active this is a [ModalSurface], so it captures navigation keys ahead
/// of the editor, focus ring and other shortcuts. It operates on the shared
/// [StatusSelection] so every selectable contribution stays in sync.
final class StatusCycleController implements ModalSurface {
  StatusCycleController(this._context);

  final ConsoleContext _context;

  StatusSelection get _selection => _context.statusSelection;

  bool _open = false;

  /// F5 engages (or toggles off) status cycling. While cycling, the mode
  /// owns navigation keys even if the input prompt is armed — selecting a
  /// status item is deliberate, so Enter activates it rather than submitting.
  bool get isActive => _open;

  /// Toggle cycling mode. No-op when no segments are registered.
  void toggle() {
    if (_open || !_selection.hasSegments) {
      dismiss();
      return;
    }
    _selection.engage();
    _open = true;
    _repaint();
  }

  /// Leave cycling mode.
  void dismiss() {
    if (!_open) return;
    _open = false;
    _selection.cancel();
    _repaint();
  }

  @override
  bool handleEvent(InputEvent event) {
    switch (event) {
      case EscapeKey():
        dismiss();
        return true;
      case FunctionKey(code: FunctionKeyCode.f5):
        dismiss();
        return true;
      case ControlKey(code: ControlCode.tab):
        _selection.cycle(1);
        _repaint();
        return true;
      case ControlKey(code: ControlCode.backtab):
        _selection.cycle(-1);
        _repaint();
        return true;
      case ArrowKey(:final direction)
          when direction == ArrowDirection.left || direction == ArrowDirection.up:
        _selection.cycle(-1);
        _repaint();
        return true;
      case ArrowKey(:final direction)
          when direction == ArrowDirection.right || direction == ArrowDirection.down:
        _selection.cycle(1);
        _repaint();
        return true;
      case ControlKey(code: ControlCode.enter):
        _selection.activate();
        _open = false;
        _repaint();
        return true;
      default:
        return true; // swallow other keys while cycling (modal)
    }
  }

  void _repaint() => _context.refreshStatus();
}
