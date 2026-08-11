import 'focusable.dart';
import 'input_event.dart';
import 'menu.dart';
import 'rect.dart';
import 'region.dart';
import 'screen.dart';

/// Interactive desktop-style menu bar.
///
/// Renders menu labels on the top row of the terminal. Owns an [OverlayRegion]
/// for the dropdown panel. Routes arrow keys, Enter, and Esc when active.
///
/// Usage: construct with a [Screen] and a list of [Menu]s, then set via
/// `editor.menuBar = menuBar`. The editor calls [handleEvent] before its own
/// dispatch; when the menu bar is active it consumes all navigation keys.
class MenuBar implements Focusable {
  final Screen _screen;
  final List<Menu> _menus;
  late final OverlayRegion _dropdown;

  // Navigation state.
  bool _active = false; // bar has focus
  bool _open = false; // a dropdown is expanded
  int _selectedMenu = 0; // index into _menus
  int _selectedItem = 0; // index into current menu's items

  /// Invoked when the bar is activated via F10/Alt+letter so the host can
  /// make the menu the focused panel (syncing the focus tint/routing).
  void Function()? onRequestFocus;

  // Precomputed label positions: the column where each menu label starts.
  List<int> _labelStarts = [];

  MenuBar(this._screen, this._menus) {
    _dropdown = OverlayRegion(_screen, Rect.empty);
    _computeLabelStarts();
  }

  bool get isActive => _active || _open;

  // -- Focusable ---------------------------------------------------------
  //
  // Focus reuses activate()/deactivate(): focusing the bar via the ring
  // highlights it (active, no dropdown). In that state the bar is *not*
  // modal — Tab cycles the ring, text/Ctrl-keys fall through to the editor,
  // and down-arrow or Enter opens a dropdown. Only with a dropdown open
  // (_open) does the bar consume everything (modal navigation).

  @override
  bool get hasFocus => _active;

  @override
  bool get canFocus => _menus.isNotEmpty && _screen.layout.hasMenuBar;

  @override
  Rect get bounds {
    if (!_screen.layout.hasMenuBar) return Rect.empty;
    final row = _screen.layout.menuTopBorderRow;
    if (row < 0) return Rect.empty;
    // The menu occupies its full 3-row bordered box (rows 0–2).
    return Rect(row: row, col: 0, width: _screen.layout.width, height: 3);
  }

  @override
  void focus() {
    activate();
    _screen.focusFrame(FrameBox.menu);
  }

  @override
  void blur() {
    deactivate();
    // Tint cleared by the new focus's focusFrame().
  }

  @override
  void highlight() => _screen.highlightFrame(FrameBox.menu);

  @override
  void unhighlight() => _screen.highlightFrame(null);

  // -- Public API ----------------------------------------------------------

  /// Attempt to handle an [InputEvent]. Returns `true` if the event was
  /// consumed by the menu bar (meaning the caller should NOT process it).
  bool handleEvent(InputEvent event) {
    // No menu strip in the layout → never intercept input. The bar may still
    // be constructed and wired to the editor (so the host can bring it back by
    // giving the layout a menu row), but until then it must be fully inert —
    // otherwise Alt+letter / F10 would pop a dropdown over the panels that now
    // own those rows. Mirrors the hasMenuBar guards on render/canFocus/bounds.
    if (!_screen.layout.hasMenuBar) return false;
    if (!_active && !_open) {
      // Inactive — check for Alt+letter or F10 to activate.
      if (event is AltKey) {
        final idx = _menus.indexWhere((m) => m.shortcut == event.letter);
        if (idx >= 0) {
          onRequestFocus?.call(); // sync focus before activating
          _selectedMenu = idx;
          _active = true;
          _open = true;
          _selectedItem = _firstSelectableItem(idx);
          _renderBar();
          _renderDropdown();
          return true;
        }
        return false;
      }
      if (event is FunctionKey && event.code == FunctionKeyCode.f10) {
        onRequestFocus?.call(); // sync focus before activating
        activate();
        return true;
      }
      // Esc no longer activates the bar — it returns focus to chat. Activate
      // via Alt+letter, F10, or the focus ring (Ctrl+G / Tab) instead.
      return false;
    }

    // Active state — consume all navigation keys.
    switch (event) {
      case ScrollEvent():
        return false; // the wheel scrolls the chat, never the menu bar.
      case EscapeKey():
        if (_open) {
          _open = false;
          _dropdown.hide();
          _renderBar();
        } else {
          deactivate();
        }
        return true;

      case ArrowKey(:final direction):
        // Ctrl+arrows are panel spatial-navigation (FocusManager). Only grab
        // them when a dropdown is actually open; otherwise let them fall
        // through so the user can steer away from the menu.
        if (event.hasCtrl) return _open;
        switch (direction) {
          case ArrowDirection.left:
            _moveMenu(-1);
            return true;
          case ArrowDirection.right:
            _moveMenu(1);
            return true;
          case ArrowDirection.down:
            if (!_open) {
              _open = true;
              _selectedItem = _firstSelectableItem(_selectedMenu);
              _renderBar();
              _renderDropdown();
            } else {
              _moveItem(1);
            }
            return true;
          case ArrowDirection.up:
            if (_open) _moveItem(-1);
            return true;
          case ArrowDirection.pageUp:
          case ArrowDirection.pageDown:
            return true;
        }

      case ControlKey(:final code):
        if (code == ControlCode.enter) {
          _activateSelectedItem();
          return true;
        }
        // With no dropdown open, let Tab / Ctrl+keys fall through — Tab cycles
        // the focus ring, Ctrl+G exits, etc. Eat them only when modal.
        return _open;

      case AltKey(:final letter):
        // Alt+letter while active — switch to that menu.
        final idx = _menus.indexWhere((m) => m.shortcut == letter);
        if (idx >= 0) {
          _selectedMenu = idx;
          _open = true;
          _selectedItem = _firstSelectableItem(idx);
          _renderBar();
          _renderDropdown();
        }
        return true;

      case FunctionKey(:final code):
        if (code == FunctionKeyCode.f10) {
          deactivate();
          return true;
        }
        return true;

      case CharInput():
        // Mnemonic jump: if char matches a menu item's first letter, jump to it.
        if (_open) {
          final lower = event.text.toLowerCase();
          final menu = _menus[_selectedMenu];
          for (var i = 0; i < menu.items.length; i++) {
            final item = menu.items[i];
            if (item is MenuEntry &&
                item.enabled &&
                item.label.toLowerCase().startsWith(lower)) {
              _selectedItem = i;
              _renderDropdown();
              _activateSelectedItem();
              return true;
            }
          }
        }
        // No dropdown: let text fall through to the editor. Modal otherwise.
        return _open;

      case EditingKey():
      case UnknownEscape():
      case PasteInput():
        // Fall through when not modal; eat everything while a dropdown is open.
        return _open;
    }
  }

  /// Activate the bar (focus first menu) without opening a dropdown.
  void activate() {
    if (_menus.isEmpty) return;
    _active = true;
    _open = false;
    _selectedMenu = 0;
    _renderBar();
  }

  /// Deactivate and close everything.
  void deactivate() {
    _active = false;
    _open = false;
    _dropdown.hide();
    _renderBar();
  }

  /// Render the bar labels on the menu bar row. Called after construction and
  /// after resize.
  void render() {
    _computeLabelStarts();
    _renderBar();
  }

  /// Release the overlay.
  void dispose() {
    _dropdown.dispose();
  }

  // -- Rendering -----------------------------------------------------------

  void _computeLabelStarts() {
    _labelStarts = [];
    // Labels render as ' label ' starting at the box interior (col 1), so the
    // first letter sits at col 2 (col 0 = box border, col 1 = leading space).
    var col = 2;
    for (final menu in _menus) {
      _labelStarts.add(col);
      col += menu.label.length + 2; // label + two spaces
    }
  }

  void _renderBar() {
    if (!_screen.layout.hasMenuBar) return;
    final row = _screen.layout.menuBarRow;
    if (row < 0) return;
    final w = _screen.layout.width;
    final useColor = _screen.ansi.useColor;

    // Build the full bar line.
    final parts = <String>[];
    for (var i = 0; i < _menus.length; i++) {
      final menu = _menus[i];
      final highlighted = _active && i == _selectedMenu;
      var label = ' ${menu.label} ';
      if (highlighted) {
        // Include the padding spaces inside the highlighting so text
        // doesn't shift columns.
        label = useColor
            ? _screen.colorize(_screen.theme.menu.barHighlight, ' ${menu.label} ')
            : '[${menu.label}]';
      } else if (_active) {
        // Dim unselected menus when bar is active.
        label = useColor ? _screen.colorize(_screen.theme.menu.barDim, ' ${menu.label} ') : ' ${menu.label} ';
      }
      parts.add(label);
    }
    final content = parts.join();
    // Pad to the box interior (cols 1..w-2; cols 0 and w-1 are borders).
    final padding = (w - 2) - _visibleLen(content, useColor);
    final line = padding > 0 ? content + ' ' * padding : content;

    _screen.putAtAbsolute(
      row: row,
      col: 1,
      text: line,
      maxCols: w - 2,
      moveCursor: false,
    );
  }

  int _visibleLen(String s, bool useColor) {
    if (!useColor) {
      // Strip ANSI for length calculation.
      var len = 0;
      var i = 0;
      while (i < s.length) {
        if (s[i] == '\x1b') {
          i++;
          if (i < s.length && s[i] == '[') {
            i++;
            while (i < s.length && (s.codeUnitAt(i) < 0x40 || s.codeUnitAt(i) > 0x7e)) {
              i++;
            }
            if (i < s.length) i++;
          } else if (i < s.length) {
            i++;
          }
          continue;
        }
        len++;
        i++;
      }
      return len;
    }
    // When color is enabled, we still need visible length (excluding ANSI).
    return _visibleLen(s, false);
  }

  void _renderDropdown() {
    if (!_open) return;
    final menu = _menus[_selectedMenu];
    final items = menu.items;
    if (items.isEmpty) {
      _dropdown.hide();
      return;
    }

    final useColor = _screen.ansi.useColor;

    // Compute dropdown width from widest item.
    var maxLabel = 0;
    for (final item in items) {
      if (item is MenuEntry) {
        final w = item.label.length + (item.shortcutHint != null ? item.shortcutHint!.length + 2 : 0);
        if (w > maxLabel) maxLabel = w;
      } else if (item is MenuSeparator) {
        if (3 > maxLabel) maxLabel = 3;
      }
    }
    final dropWidth = maxLabel + 4; // padding each side
    final dropHeight = items.length + 2; // top/bottom border

    // Position: below the menu label, clamped to screen.
    // Place the border one column left of the label text so the item text
    // inside the dropdown aligns with the label character in the bar.
    final labelCol = _labelStarts[_selectedMenu];
    final screenW = _screen.layout.width;
    final dropCol = (labelCol - 1).clamp(0, screenW - dropWidth);
    final dropRow = _screen.layout.hasMenuBar
        ? _screen.layout.menuBottomBorderRow + 1
        : _screen.layout.topBorderRow + 1;

    _dropdown.reposition(Rect(
      row: dropRow,
      col: dropCol,
      width: dropWidth,
      height: dropHeight,
    ));

    final lines = <String>[];
    // Top border.
    lines.add('┌${'─' * (dropWidth - 2)}┐');
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is MenuSeparator) {
        lines.add('├${'─' * (dropWidth - 2)}┤');
      } else if (item is MenuEntry) {
        final selected = i == _selectedItem;
        final inner = dropWidth - 2;
        var label = item.label;
        var hint = item.shortcutHint ?? '';
        final pad = inner - label.length - hint.length - 1;
        var line = '$label${' ' * (pad < 0 ? 0 : pad)} $hint';
        if (line.length > inner) line = line.substring(0, inner);
        if (line.length < inner) line += ' ' * (inner - line.length);

        if (!item.enabled) {
          line = useColor ? _screen.colorize(_screen.theme.menu.dropdownDisabled, line) : line;
        } else if (selected) {
          line = useColor ? _screen.colorize(_screen.theme.menu.dropdownSelected, line) : '>$line<';
        }
        lines.add('│$line│');
      }
    }
    // Bottom border.
    lines.add('└${'─' * (dropWidth - 2)}┘');

    _dropdown.show(lines);
  }

  // -- Navigation helpers --------------------------------------------------

  void _moveMenu(int delta) {
    _selectedMenu = (_selectedMenu + delta) % _menus.length;
    if (_selectedMenu < 0) _selectedMenu += _menus.length;
    if (_open) {
      _selectedItem = _firstSelectableItem(_selectedMenu);
      _renderBar();
      _renderDropdown();
    } else {
      _renderBar();
    }
  }

  void _moveItem(int delta) {
    final menu = _menus[_selectedMenu];
    final items = menu.items;
    var idx = _selectedItem;
    for (var attempt = 0; attempt < items.length; attempt++) {
      idx = (idx + delta) % items.length;
      if (idx < 0) idx += items.length;
      final item = items[idx];
      if (item is MenuEntry && item.enabled) {
        _selectedItem = idx;
        _renderDropdown();
        return;
      }
    }
    // No selectable item found — don't move.
  }

  void _activateSelectedItem() {
    if (!_open) return;
    final menu = _menus[_selectedMenu];
    final items = menu.items;
    if (_selectedItem < 0 || _selectedItem >= items.length) return;
    final item = items[_selectedItem];
    if (item is MenuEntry && item.enabled) {
      deactivate();
      item.onActivate();
    }
  }

  int _firstSelectableItem(int menuIdx) {
    final items = _menus[menuIdx].items;
    for (var i = 0; i < items.length; i++) {
      if (items[i] is MenuEntry && (items[i] as MenuEntry).enabled) return i;
    }
    return 0;
  }
}
