// Probe: dump every raw notcurses input-pump record (id + modifiers) to a log
// file while the user presses keys. isolates where Option/Alt+Arrow dies —
// notcurses' decode, the pump, or tina_console's translation layers.
//
// Usage: dart run tool/altkey_probe.dart [/path/to/log]
// Default log: /tmp/altkey-probe.log. Press keys; Ctrl-C or 'q' quits.
import 'dart:async';
import 'dart:io';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:tina_console/src/backend/init_reply_guard.dart';

Future<void> main(List<String> args) async {
  final logPath = args.isNotEmpty ? args.first : '/tmp/altkey-probe.log';
  final log = File(logPath).openSync(mode: FileMode.writeOnly);
  void logLine(String s) {
    log.writeStringSync('${DateTime.now().millisecondsSinceEpoch} $s\n');
  }

  // Same init path as tina's notcurses backend: under a tmux pane (or any
  // terminal that never answers notcurses' capability queries) a bare init
  // blocks forever — the reply guard feeds a fallback DA1 reply and restores
  // fd 0 afterwards.
  final guard = TerminalReplyGuard()..prepare();
  nc.NotCurses ncs;
  try {
    ncs = nc.NotCurses(nc.CursesOptions(
      loglevel: nc.LogLevel.silent,
      flags: nc.OptionFlags.suppressBanners,
    ));
  } finally {
    guard.restore();
  }
  if (ncs.notInitialized) {
    stderr.writeln('notcurses init failed');
    exit(1);
  }
  final plane = ncs.stdplane();
  plane.putStrYX(0, 0, 'altkey probe — press Option/Alt+Left, Option+Right,');
  plane.putStrYX(1, 0, 'plain Left/Right, Esc, then Ctrl-C or q to quit.');
  plane.putStrYX(3, 0, 'records log to: $logPath');
  ncs.render();

  var done = false;
  // NOTE: no blocking sleep() in the wait loop — it would stall the isolate
  // and the native listener callbacks (the pump's records) would never be
  // delivered.
  final pump = ncs.startInputPump();
  final sub = pump.events.listen((rec) {
    final id = rec.id;
    final mods = rec.modifiers;
    final alt = (mods & nc.KeyMod.alt) != 0;
    final ctrl = (mods & nc.KeyMod.ctrl) != 0;
    final shift = (mods & nc.KeyMod.shift) != 0;
    String name;
    if (id == nc.NcKey.left) {
      name = 'LEFT';
    } else if (id == nc.NcKey.right) {
      name = 'RIGHT';
    } else if (id == nc.NcKey.up) {
      name = 'UP';
    } else if (id == nc.NcKey.down) {
      name = 'DOWN';
    } else if (id == 0x1b) {
      name = 'ESC';
    } else if (id >= 0x20 && id < 0x7f) {
      name = "'${String.fromCharCode(id)}'";
    } else {
      name = 'id';
    }
    logLine('pump: $name id=0x${id.toRadixString(16)} '
        'mods=$mods${alt ? ' ALT' : ''}${ctrl ? ' CTRL' : ''}${shift ? ' SHIFT' : ''}');

    if (id == 0x71 && mods == 0) done = true; // plain 'q'
    if (id == 0x03) done = true; // Ctrl-C
  });

  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (!done && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  logLine('probe exit');
  await sub.cancel();
  pump.stop();
  log.close();
  ncs.stop();
  exit(0);
}
