library;

import 'package:tina_engine_2/tina_engine_2.dart';

import 'mode_control.dart';
import 'permissions.dart';

/// Publishes the `/mode` command into the shared [Commands] registry.
final class ModeCommandPlugin extends AgentPlugin {
  ModeCommandPlugin({required this.mode, this.terminal, this.id = 'tina/mode'});

  @override
  final String id;
  final ModeControl mode;
  final Terminal? terminal;

  @override
  List<Command> get commands => [command];

  /// The mode words, in the order help presents them. The vocabulary
  /// lives here, once — nothing else in the workspace string-matches a
  /// mode word.
  static const modeWords = ['normal', 'read-only'];

  /// One word in, one mode out — null when the word is not a mode.
  /// (Handy for tests and future callers; the command itself goes
  /// through [Command.handler].)
  static PermissionMode? parseMode(String word) => switch (word.trim()) {
        'normal' => PermissionMode.normal,
        'read-only' => PermissionMode.readOnly,
        _ => null,
      };

  /// One mode out, one word back — the same vocabulary, both directions,
  /// so nothing else ever writes 'readOnly' at a user.
  static String wordFor(PermissionMode mode) =>
      mode == PermissionMode.readOnly ? 'read-only' : 'normal';

  /// The command this plugin owns: parse the word, flip the mode
  /// control, tell the terminal what happened. A bare `/mode` prints
  /// the current mode; an invalid argument changes nothing and says so
  /// — refusal is a message, never a throw.
  Command get command => Command(
        name: 'mode',
        description:
            'switch the permission mode, argument: ${modeWords.join(' or ')}',
        handler: _switch,
        complete: (prefix) => modeWords.where((word) => word.startsWith(prefix)).toList(),
      );

  void _switch(String argument) {
    final word = argument.trim();
    if (word.isEmpty) {
      // No argument: show the mode, change nothing.
      terminal?.writeln('mode: ${wordFor(this.mode.mode)}');
      return;
    }
    final mode = parseMode(word);
    if (mode == null) {
      terminal?.writeln('no mode named $word');
      return;
    }
    this.mode.mode = mode;
    terminal?.writeln('mode: $word');
  }
}
