/// A single menu bar entry: a top-level label with a dropdown of items.
class Menu {
  /// Display label (e.g. "File").
  final String label;

  /// Lowercase code unit of the Alt-key shortcut character in [label].
  /// For example, `0x66` for Alt+F (the 'f' in "File").
  final int shortcut;

  /// Ordered list of items in the dropdown.
  final List<MenuItem> items;

  const Menu({
    required this.label,
    required this.shortcut,
    required this.items,
  });
}

/// An item within a dropdown menu.
sealed class MenuItem {
  const MenuItem();
}

/// A selectable entry with an optional keyboard shortcut hint.
class MenuEntry extends MenuItem {
  final String label;
  final String? shortcutHint;
  final void Function() onActivate;
  final bool enabled;

  const MenuEntry({
    required this.label,
    this.shortcutHint,
    required this.onActivate,
    this.enabled = true,
  });
}

/// A horizontal separator line.
class MenuSeparator extends MenuItem {
  const MenuSeparator();
}
