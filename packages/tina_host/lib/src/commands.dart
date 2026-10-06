import 'package:tina_core/tina_core.dart';

/// The command registry: publish, look up, list.
final class Commands {
  final Map<String, Command> _byName = {};
  final Map<String, String> _owners = {};
  final Map<String, Command> _byPrefix = {};

  void removeOwner(String owner) {
    for (final name
        in _owners.keys.where((name) => _owners[name] == owner).toList()) {
      final command = _byName.remove(name);
      if (command?.inputPrefix case final String prefix) {
        _byPrefix.remove(prefix);
      }
      _owners.remove(name);
    }
  }

  /// Publish [command]. Re-publishing a name throws — two plugins own
  /// one word is a wiring bug, not a runtime choice.
  void publish(Command command, {String? owner}) {
    validate([command]);
    _byName[command.name] = command;
    if (command.inputPrefix case final String prefix) {
      _byPrefix[prefix] = command;
    }
    if (owner != null) _owners[command.name] = owner;
  }

  /// Validate a batch before a plugin opens resources or publishes anything.
  void validate(Iterable<Command> commands) {
    final names = _byName.keys.toSet();
    final prefixes = _byPrefix.keys.toSet();
    for (final command in commands) {
      if (!names.add(command.name)) {
        throw StateError('command "${command.name}" is already published');
      }
      final prefix = command.inputPrefix;
      if (prefix == null) continue;
      if (prefix.isEmpty ||
          prefix.startsWith('/') ||
          RegExp(r'\s').hasMatch(prefix)) {
        throw ArgumentError.value(prefix, 'inputPrefix',
            'must be nonempty, contain no whitespace, and not start with /');
      }
      if (!prefixes.add(prefix)) {
        throw StateError('command prefix "$prefix" is already published');
      }
    }
  }

  /// Match the longest registered prefix. Callers retain slash dispatch.
  ({Command command, String argument})? matchPrefix(String line) {
    String? matched;
    for (final prefix in _byPrefix.keys) {
      if (line.startsWith(prefix) &&
          (matched == null || prefix.length > matched.length)) {
        matched = prefix;
      }
    }
    if (matched == null) return null;
    return (
      command: _byPrefix[matched]!,
      argument: line.substring(matched.length).trim()
    );
  }

  /// The published command named [name] (no slash), or null.
  Command? operator [](String name) => _byName[name];

  /// Every published command, sorted by name — the stable order a front
  /// end presents.
  List<Command> get all => List.unmodifiable(
      _byName.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
}
