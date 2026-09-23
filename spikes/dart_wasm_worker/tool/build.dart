// Builds the spike: dart2wasm compile + Node smoke test.
//
//   dart run tool/build.dart          compile + node smoke test
//   dart run tool/build.dart --watch  (no watch; rerun by hand)
//
// The workerd leg is deliberately manual (it's a long-running server):
//   npx --yes wrangler@latest dev --port 8787
//   curl http://127.0.0.1:8787/health
import 'dart:io';

Future<void> main() async {
  final root = Directory.current.path;
  final build = Directory('$root/build');
  await build.create(recursive: true);

  final compile = await Process.run('dart', [
    'compile',
    'wasm',
    '-o',
    '$build/main.wasm',
    '$root/bin/main.dart',
  ]);
  stdout.write(compile.stdout);
  stderr.write(compile.stderr);
  if (compile.exitCode != 0) exit(compile.exitCode);

  final smoke = await Process.run('node', ['$root/test/smoke.mjs']);
  stdout.write(smoke.stdout);
  stderr.write(smoke.stderr);
  exit(smoke.exitCode);
}
