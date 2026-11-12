/// The no-`dart:io` variant of the terminal-background probe (wasm
/// compilation): the host owns the terminal, so there is no OSC-11
/// round-trip and no platform heuristic. The background resolves to dark
/// (the composition root picks the theme variant explicitly; a tty-based
/// probe import is a documented follow-up).
library;

import 'dart:async';

import 'terminal_bg.dart';

/// No platform facts under wasm: the theme chooses explicitly, so this
/// only shapes any heuristic that still asks.
TerminalBg bgFromPlatform() => TerminalBg.dark;

/// No OSC-11 round-trip under wasm: the host owns stdin/stdout bytes.
/// Returns [TerminalBg.unknown] without writing anything.
Future<TerminalBg> probeTerminalBg({
  Duration timeout = const Duration(milliseconds: 200),
  Stream<List<int>>? probeStdin,
}) async {
  return TerminalBg.unknown;
}
