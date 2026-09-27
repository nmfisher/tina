/// The mode's command: `/mode` — one word, one flip, told through the
/// terminal.
///
/// This plugin owns the mode's **vocabulary as data** — the words a user
/// types (`normal`, `read-only`) and nothing else. It implements no
/// engine phases: a command has no turn to shape. It reads the two
/// services it needs — the [Terminal] to tell, the mode control to
/// flip — from the locator **at use** (registration order never
/// matters), validates, switches, and tells what happened. The engine
/// stays command-blind; the shell stays mode-blind: it dispatches by
/// name and hands over, never learning what a mode is.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_services/tina_services.dart';

import 'mode_control.dart';
import 'permissions.dart';

/// Publishes the `/mode` command into the shared [Commands] registry.
final class ModeCommandPlugin extends AgentPlugin {
  /// [locator] is the session's shared services — the plugin is
  /// constructed with it and holds it; resolution happens later, at
  /// use, so construction order never matters.
  ModeCommandPlugin(Services locator, {this.id = 'mode-command'})
      : _locator = locator;

  @override
  final String id;

  final Services _locator;

  bool _published = false;

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
      );

  void _switch(String argument) {
    final terminal = _locator.get<Terminal>();
    final word = argument.trim();
    if (word.isEmpty) {
      // No argument: show the mode, change nothing.
      terminal.writeln('mode: ${wordFor(_locator.get<ModeControl>().mode)}');
      return;
    }
    final mode = parseMode(word);
    if (mode == null) {
      terminal.writeln('no mode named $word');
      return;
    }
    // Resolved at use: the boundary may have mounted after this plugin
    // was constructed — that is the locator's whole point.
    _locator.get<ModeControl>().mode = mode;
    terminal.writeln('mode: $word');
  }

  /// Publish the command into the session's registry. Idempotent: the
  /// registry refuses a second `/mode`, and this plugin will not be the
  /// one to trip over it.
  void register() {
    if (_published) return;
    _locator.get<Commands>().publish(command);
    _published = true;
  }
}
