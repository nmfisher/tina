import 'dart:io' show stdin;

import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/src/backend/ansi_input_backend.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina/platform/terminal_geometry.dart';

import 'startup_session_picker_overlay.dart';

/// Production entry point for interactive `--resume`: overlays a
/// keyboard-navigable, type-to-filter session list on a standalone
/// alt-screen and returns the chosen session id (null on cancel).
///
/// Owns the terminal lifecycle the overlay needs: raw mode (arrow keys and
/// per-keystroke filtering arrive unbuffered — canonical mode would withhold
/// everything until Enter), one [AnsiInputBackend] for the whole picker run,
/// and their restoration on exit. The backend rides the shared stdin relay
/// ([LiveStdio]) so the TUI's later backend can subscribe afterwards without
/// an "already listened" fight.
Future<String?> pickStartupSessionId(List<SessionMeta> sessions) async {
  final choices = [
    for (final m in sessions) SessionChoice.fromMeta(m),
  ];
  try {
    stdin.echoMode = false;
    stdin.lineMode = false;
  } catch (_) {}
  final backend = AnsiInputBackend(io: const LiveStdio());
  await backend.ready;
  try {
    final choice = await pickStartupSessionOverlay(
      choices: choices,
      readEvent: () => backend.events.first,
      geometry: const StdoutTerminalGeometry(),
    );
    return choice?.meta.id;
  } finally {
    backend.dispose();
    try {
      stdin.echoMode = true;
      stdin.lineMode = true;
    } catch (_) {}
  }
}
