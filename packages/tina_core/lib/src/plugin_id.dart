/// Canonical plugin identifiers use a publisher namespace and a local name.
/// The plugin registry reserves `tina` for its first-party catalog.
void validatePluginId(String id) {
  if (!RegExp(r'^[a-z][a-z0-9-]*/[a-z][a-z0-9-]*$').hasMatch(id)) {
    throw ArgumentError.value(id, 'plugin id',
        'expected lowercase publisher/name (letters, digits and hyphens)');
  }
}
