import 'focusable.dart';
import 'input_event.dart';

/// Owns an ordered ring of [Focusable]s and separates two states:
///
/// - **Focus** — the one panel that receives input. Persistent until another
///   panel is focused. Shown with the focus (cyan) border.
/// - **Cycling highlight** — the panel being navigated to while cycling.
///   Transient. Shown with the highlight (yellow) border. A panel is never
///   both focused and highlighted at once.
///
/// Cycling is **modal**: while a panel is highlighted, arrows/Tab move the
/// highlight, Enter commits it to the focus, and Esc cancels. The focused
/// panel doesn't receive keys during cycling — so a panel that uses arrows
/// for its own purposes (e.g. the menu switching File/Edit/Help) only claims
/// them once it's *focused*, never while it's merely highlighted.
///
/// Default key bindings:
/// - **Ctrl+W / Ctrl+G** (not cycling) → engage: highlight the next panel
///   after the focused one. (While cycling, either cancels.)
/// - **↑ ↓ ← →** (cycling) → move the highlight toward that direction.
/// - **Tab** (cycling) → move the highlight to the next panel.
/// - **Enter** (cycling) → commit: the highlighted panel becomes the focus.
/// - **Esc** (cycling) → cancel: clear the highlight, keep the current focus.
/// - **Esc** (not cycling, focus ≠ home) → return focus to the home panel.
class FocusManager {
  final List<Focusable> _ring = [];
  int _focusIndex = -1; // the focused (input) panel; -1 if none.
  int _cyclingIndex = -1; // the cycling highlight; -1 = not cycling.
  Focusable? _home;

  /// The default/launch focus and the panel Esc returns to (typically chat).
  /// Assigning it while no panel is focused focuses it immediately.
  set home(Focusable? value) {
    _home = value;
    if (_focusIndex < 0 && value != null) {
      _focusIndex = _ring.indexOf(value);
      if (_focusIndex >= 0) _ring[_focusIndex].focus();
    }
  }

  Focusable? get home => _home;

  /// Register a focusable so it participates in the ring.
  void register(Focusable f) => _ring.add(f);

  /// Remove [f] from the ring, clearing focus/highlight if it held either.
  void unregister(Focusable f) {
    final i = _ring.indexOf(f);
    if (i < 0) return;
    if (i == _cyclingIndex) {
      _ring[i].unhighlight();
      _cyclingIndex = -1;
    }
    if (i == _focusIndex) {
      _ring[i].blur();
      _focusIndex = -1;
    }
    _ring.removeAt(i);
    if (_cyclingIndex > i) _cyclingIndex--;
    if (_focusIndex > i) _focusIndex--;
  }

  /// The focused (input) panel, or null if none.
  Focusable? get focused => _inRange(_focusIndex) ? _ring[_focusIndex] : null;

  /// The cycling-highlighted panel, or null when not cycling.
  Focusable? get highlighted =>
      _inRange(_cyclingIndex) ? _ring[_cyclingIndex] : null;

  /// Whether cycling is active (a panel is highlighted).
  bool get isCycling => _cyclingIndex >= 0;

  // -- Cycling -------------------------------------------------------------

  /// Engage cycling: highlight the currently focused panel (it turns yellow,
  /// since the focus tint is suppressed while cycling). Arrows then move the
  /// highlight from there. No-op if already cycling or nothing is focused.
  void engage() {
    if (_cyclingIndex >= 0) return;
    if (!_inRange(_focusIndex)) return;
    _setCycling(_focusIndex);
  }

  /// Move the highlight to the next/previous cyclable panel (Tab).
  void moveHighlightCyclic(int dir) {
    if (_cyclingIndex < 0) return;
    final next = _nextCyclable(_cyclingIndex, dir);
    if (next >= 0) _setCycling(next);
  }

  /// Move the highlight to the nearest panel in [dir] (arrows).
  void moveHighlightDirection(ArrowDirection dir) {
    if (_cyclingIndex < 0) return;
    final next = _nearestInDirection(_cyclingIndex, dir);
    if (next >= 0) _setCycling(next);
  }

  /// Commit: the highlighted panel becomes the focus. No-op if not cycling.
  void commit() {
    if (_cyclingIndex < 0) return;
    if (_inRange(_focusIndex)) _ring[_focusIndex].blur();
    _focusIndex = _cyclingIndex;
    _cyclingIndex = -1;
    // focus() clears the cycling highlight itself, so don't unhighlight the
    // target first — that would paint a plain (unfocused) frame between the
    // yellow highlight and the cyan focus and read as a flash. (cancel() still
    // unhighlights, since it clears the highlight without focusing.)
    _ring[_focusIndex].focus();
  }

  /// Cancel cycling: clear the highlight, keep the current focus.
  void cancel() {
    if (_cyclingIndex < 0) return;
    _ring[_cyclingIndex].unhighlight();
    _cyclingIndex = -1;
  }

  /// Return focus to the home panel. No-op if home isn't set or already home.
  void returnHome() {
    final homeIdx = _home == null ? -1 : _ring.indexOf(_home!);
    if (homeIdx < 0 || homeIdx == _focusIndex) return;
    if (_inRange(_focusIndex)) _ring[_focusIndex].blur();
    _focusIndex = homeIdx;
    _ring[_focusIndex].focus();
  }

  /// Focus a specific panel directly (e.g. the menu via F10/Alt), bypassing
  /// cycling. Cancels any cycling, blurs the current focus, focuses [f].
  void focusPanel(Focusable f) {
    final idx = _ring.indexOf(f);
    if (idx < 0) return;
    if (_cyclingIndex >= 0) cancel();
    if (idx == _focusIndex) return;
    if (_inRange(_focusIndex)) _ring[_focusIndex].blur();
    _focusIndex = idx;
    _ring[_focusIndex].focus();
  }

  /// Release focus from the currently focused panel entirely (no new panel
  /// takes it). Used when a modal becomes the active surface: the conversation
  /// panel must stop being blue while the modal is up. Sets the focus index to
  /// -1 so a later [focusPanel] reliably re-focuses (an index match would
  /// otherwise early-return), keeping "exactly one blue panel" consistent.
  void blurFocused() {
    if (!_inRange(_focusIndex)) return;
    _ring[_focusIndex].blur();
    _focusIndex = -1;
  }

  void _setCycling(int i) {
    if (_inRange(_cyclingIndex)) _ring[_cyclingIndex].unhighlight();
    _cyclingIndex = i;
    _ring[i].highlight();
  }

  // -- Input --------------------------------------------------------------

  /// Handle [event]. Returns true if consumed.
  ///
  /// While cycling, the manager is modal: it owns arrows/Tab/Enter/Esc and
  /// swallows everything else. When not cycling, only the entry keys and Esc
  /// (return-home) are consumed; other events fall through so the dispatch can
  /// route them to the focused panel.
  bool handleEvent(InputEvent event) {
    final isEntryKey = event is ControlKey &&
        (event.code == ControlCode.ctrlW || event.code == ControlCode.ctrlG);
    if (_cyclingIndex >= 0) {
      if (event is ArrowKey) {
        moveHighlightDirection(event.direction);
        return true;
      }
      if (event is ControlKey && event.code == ControlCode.tab) {
        moveHighlightCyclic(1);
        return true;
      }
      if (event is ControlKey && event.code == ControlCode.enter) {
        commit();
        return true;
      }
      if (event is EscapeKey || isEntryKey) {
        cancel();
        return true;
      }
      return true; // swallow other keys while cycling (modal)
    }
    if (isEntryKey) {
      engage();
      return true;
    }
    if (event is EscapeKey) {
      final homeIdx = _home == null ? -1 : _ring.indexOf(_home!);
      if (homeIdx >= 0 && _focusIndex != homeIdx) {
        returnHome();
        return true;
      }
      return false; // at home — let the editor's double-Esc clear run
    }
    return false; // route to the focused panel
  }

  // -- Internals ----------------------------------------------------------

  bool _inRange(int i) => i >= 0 && i < _ring.length;

  /// Next cyclable panel after [from] in direction [dir] (skipping the
  /// focused panel). -1 if none.
  int _nextCyclable(int from, int dir) {
    if (_ring.isEmpty) return -1;
    var i = from < 0 ? -1 : from;
    for (var step = 0; step < _ring.length; step++) {
      i = (i + dir) % _ring.length;
      if (i < 0) i += _ring.length;
      if (_ring[i].canFocus) return i;
    }
    return -1;
  }

  /// Nearest panel to [from] in [dir], skipping the focused panel. Scoring:
  /// strictly-beyond, aligned wins, nearer wins. -1 if none.
  int _nearestInDirection(int from, ArrowDirection dir) {
    if (!_inRange(from)) return -1;
    final currentRect = _ring[from].bounds;
    if (currentRect.isEmpty) return -1;

    var bestScore = 0x7fffffffffffff;
    var bestIdx = -1;
    for (var i = 0; i < _ring.length; i++) {
      if (i == from) continue;
      final candidate = _ring[i];
      if (!candidate.canFocus) continue;
      final rect = candidate.bounds;
      if (rect.isEmpty) continue;

      final int primaryDist;
      final int perpOverlap;
      final int perpGap;
      switch (dir) {
        case ArrowDirection.right:
          if (rect.col <= currentRect.right) continue;
          primaryDist = rect.col - currentRect.right;
          perpOverlap =
              _rangeOverlap(rect.row, rect.bottom, currentRect.row, currentRect.bottom);
          perpGap = _rangeGap(rect.row, rect.bottom, currentRect.row, currentRect.bottom);
        case ArrowDirection.left:
          if (rect.right >= currentRect.col) continue;
          primaryDist = currentRect.col - rect.right;
          perpOverlap =
              _rangeOverlap(rect.row, rect.bottom, currentRect.row, currentRect.bottom);
          perpGap = _rangeGap(rect.row, rect.bottom, currentRect.row, currentRect.bottom);
        case ArrowDirection.down:
          if (rect.row <= currentRect.bottom) continue;
          primaryDist = rect.row - currentRect.bottom;
          perpOverlap =
              _rangeOverlap(rect.col, rect.right, currentRect.col, currentRect.right);
          perpGap = _rangeGap(rect.col, rect.right, currentRect.col, currentRect.right);
        case ArrowDirection.up:
          if (rect.bottom >= currentRect.row) continue;
          primaryDist = currentRect.row - rect.bottom;
          perpOverlap =
              _rangeOverlap(rect.col, rect.right, currentRect.col, currentRect.right);
          perpGap = _rangeGap(rect.col, rect.right, currentRect.col, currentRect.right);
        case ArrowDirection.pageUp:
        case ArrowDirection.pageDown:
          continue;
      }
      final alignedPenalty = perpOverlap > 0 ? 0 : 1000000000;
      final score = alignedPenalty + primaryDist * 10000 + perpGap;
      if (score < bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  static int _rangeOverlap(int a1, int a2, int b1, int b2) {
    final start = a1 > b1 ? a1 : b1;
    final end = a2 < b2 ? a2 : b2;
    return end >= start ? (end - start + 1) : 0;
  }

  static int _rangeGap(int a1, int a2, int b1, int b2) {
    if (a2 < b1) return b1 - a2;
    if (b2 < a1) return a1 - b2;
    return 0;
  }
}
