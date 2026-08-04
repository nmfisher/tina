// Standalone: dart run test/tools/nc_key_dump.dart
// Dumps raw notcurses key metadata to stderr. Press Ctrl+C to exit.
import 'dart:io';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;

void main() {
  final ncc = nc.NotCurses(nc.CursesOptions(
    loglevel: nc.LogLevel.silent,
    flags: nc.OptionFlags.suppressBanners,
  ));
  if (ncc.notInitialized) {
    stderr.writeln('notcurses init failed');
    exit(1);
  }

  stderr.writeln('nc_key_dump: Press Option+Left, Option+Right, plain b, plain f, Ctrl+C');
  final plane = ncc.stdplane();
  var line = 0;

  while (true) {
    final result = ncc.getNonBlocking(keyInfo: true);
    if (result.value == null || result.result == 0) {
      sleep(const Duration(milliseconds: 16));
      continue;
    }
    final key = result.value!;

    final msg = 'id=0x${key.id.toRadixString(16).padLeft(4, '0')}'
        ' (${key.id}) alt=${key.hasAlt()} ctrl=${key.hasCtrl()}'
        ' syn=${key.keySynthesizedP()} mod=0x${key.modifiers.toRadixString(16)}'
        ' str="${key.keyStr}"';
    plane.putStrYX(line++, 0, msg);
    ncc.render();
    stderr.writeln(msg);

    if (key.id == 0x03) break; // Ctrl+C
    key.destroy();
  }

  ncc.stop();
}
