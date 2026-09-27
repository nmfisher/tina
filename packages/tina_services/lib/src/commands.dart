/// The command registry — how a front end offers slash commands without
/// importing the packages the commands come from.
///
/// A plugin publishes the commands it owns; the front end reads them and
/// presents them however it likes (`/word` today). The handler receives
/// the argument text and returns nothing: **the terminal does the
/// writing** — a handler that wanted to return a string would turn the
/// registry into a renderer. Built-ins are the shell's, registered by
/// the shell; unknown `/words` are the front end's problem, not a
/// registry miss.
library;

/// One command a plugin owns.
final class Command {
  /// The word after the slash, no slash, no spaces.
  final String name;

  /// One line — what it does and what its argument takes. The front end
  /// presents it however it likes.
  final String description;

  /// Runs the command with everything after the command word, trimmed.
  /// Returns nothing: the handler reports through the [Terminal] it
  /// resolves from the locator. Validation is the command's own job —
  /// an invalid argument changes nothing and says so through the
  /// terminal, never by throwing.
  final void Function(String argument) handler;

  const Command({
    required this.name,
    required this.description,
    required this.handler,
  });
}

/// The command registry: publish, look up, list.
final class Commands {
  final Map<String, Command> _byName = {};

  /// Publish [command]. Re-publishing a name throws — two plugins own
  /// one word is a wiring bug, not a runtime choice.
  void publish(Command command) {
    if (_byName.containsKey(command.name)) {
      throw StateError('command "${command.name}" is already published');
    }
    _byName[command.name] = command;
  }

  /// The published command named [name] (no slash), or null.
  Command? operator [](String name) => _byName[name];

  /// Every published command, sorted by name — the stable order a front
  /// end presents.
  List<Command> get all => List.unmodifiable(
      _byName.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
}
