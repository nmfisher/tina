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

  /// The handler may run while a conversation turn is active. Owners opt in
  /// only when the command does not require an idle loop; dispatchers otherwise
  /// keep it queued. Interactive handlers still share the frontend input owner.
  final bool allowWhileRunning;

  /// An optional prefix alias: the text after it is the entire argument.
  /// For example, `!echo hi` can invoke `/shell echo hi`. Slash commands
  /// continue to use [name]; plugins own their other input prefixes.
  final String? inputPrefix;

  /// Cancel this command's active work, when it supports cancellation.
  final void Function()? cancel;

  const Command({
    required this.name,
    required this.description,
    required this.handler,
    this.complete,
    this.allowWhileRunning = false,
    this.inputPrefix,
    this.cancel,
  });
}
