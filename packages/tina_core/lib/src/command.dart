import 'dart:async';

/// One command a plugin owns.
final class Command {
  /// The word after the slash, no slash, no spaces.
  final String name;

  /// One line — what it does and what its argument takes. The front end
  /// presents it however it likes.
  final String description;

  /// Runs the command with everything after the command word, trimmed.
  /// Dispatchers await completion, including asynchronous plugin work.
  /// The handler reports through the output dependency supplied to its plugin.
  final FutureOr<void> Function(String argument) handler;

  /// Argument suggestions, without the command word. Plugins own vocabulary;
  /// frontends decide how to present it.
  final FutureOr<List<String>> Function(String prefix)? complete;

  const Command({
    required this.name,
    required this.description,
    required this.handler,
    this.complete,
  });
}
