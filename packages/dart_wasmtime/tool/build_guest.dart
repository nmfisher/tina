// Builds the pure test guest (native/guest/guest.c) to native/guest/guest.wasm.
// Requires clang with the wasm32 target and wasm-ld (see tool/README notes in
// the ticket). The guest has no imports: no WASI, no host capability surface.
// Checked-in guest.wasm is regenerated whenever guest.c changes.
import 'dart:io';

Future<void> main() async {
  final root = 'native/guest';
  final result = await Process.run('clang', [
    '--target=wasm32',
    '-O2',
    '-nostdlib',
    '-Wl,--no-entry',
    '-Wl,--export-dynamic',
    '-Wl,--allow-undefined',
    '-o',
    '$root/guest.wasm',
    '$root/guest.c',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    exitCode = result.exitCode;
    return;
  }
  final bytes = await File('$root/guest.wasm').length();
  stdout.writeln('guest.wasm: $bytes bytes');
}
