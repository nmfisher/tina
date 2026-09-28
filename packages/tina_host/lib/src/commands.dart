import 'package:tina_core/tina_core.dart';

/// The command registry: publish, look up, list.
final class Commands {
  final Map<String, Command> _byName = {};
  final Map<String, String> _owners = {};

  void removeOwner(String owner) {
    for (final name
        in _owners.keys.where((name) => _owners[name] == owner).toList()) {
      _byName.remove(name);
      _owners.remove(name);
    }
  }

  /// Publish [command]. Re-publishing a name throws — two plugins own
  /// one word is a wiring bug, not a runtime choice.
  void publish(Command command, {String? owner}) {
    if (_byName.containsKey(command.name)) {
      throw StateError('command "${command.name}" is already published');
    }
    _byName[command.name] = command;
    if (owner != null) _owners[command.name] = owner;
  }

  /// The published command named [name] (no slash), or null.
  Command? operator [](String name) => _byName[name];

  /// Every published command, sorted by name — the stable order a front
  /// end presents.
  List<Command> get all => List.unmodifiable(
      _byName.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
}
