// Builds the spike: dart2wasm → node smoke test → workerd (wrangler dev).
//
//   dart run tool/build.dart              compile + node smoke + workerd /health check
//   dart run tool/build.dart --node-only  compile + node smoke only
//   dart run tool/build.dart --dev        compile + `wrangler dev` in the foreground
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final build = Directory('$root/build');
  await build.create(recursive: true);

  final wasmPath = '$build/main.wasm';
  final compile = await Process.run('dart', [
    'compile',
    'wasm',
    '--output',
    wasmPath,
    '$root/bin/main.dart',
  ]);
  stdout.write(compile.stdout);
  stderr.write(compile.stderr);
  if (compile.exitCode != 0) {
    stderr.writeln('dart compile wasm failed (${compile.exitCode})');
    exit(compile.exitCode);
  }
  stdout.writeln('compiled: $wasmPath');

  if (!args.contains('--skip-node')) {
    final node = await _smokeTest(root);
    stdout.write(node.$1);
    stderr.write(node.$2);
    if (node.$3 != 0) {
      stderr.writeln('node smoke test failed (${node.$3})');
      exit(node.$3);
    }
    stdout.writeln('node smoke test passed');
  }

  // --dev keeps `wrangler dev` in the foreground for manual poking.
  if (args.contains('--dev')) {
    final wrangler = await Process.start('npx', [
      '--yes',
      'wrangler@latest',
      'dev',
      '--port',
      '8787',
    ], mode: ProcessStartMode.inheritStdio, workingDirectory: root);
    exit(await wrangler.exitCode);
  }

  if (args.contains('--node-only')) {
    stdout.writeln('node-only mode: skipping workerd');
    return;
  }

  // Default: run workerd headless, poll /health, report PASS/FAIL.
  final wrangler = await Process.start('npx', [
    '--yes',
    'wrangler@latest',
    'dev',
    '--port',
    '8787',
  ], workingDirectory: root);
  defer(() => wrangler.kill());

  final pass = await _pollHealth();
  exit(pass ? 0 : 1);
}

void defer(void Function() f) {
  // Process.kill on exit paths; kept explicit so failures still print.
  // (Not a real defer; called inline before exit in main.)
  f();
}

Future<(String, String, int)> _smokeTest(String root) async {
  const script = '''
import { instantiate, invoke } from './build/main.mjs';
import dartModule from './build/main.wasm';
const instance = await instantiate(dartModule);
invoke(instance);
const res = await globalThis.__dart_fetch(
  { url: 'https://spike.invalid/health', method: 'GET' },
  {}, {});
console.log('dart handler said: ' + (await res.text()));
''';
  File('$root/build/smoke.mjs').writeAsStringSync(script);
  final res = await Process.run('node', [
    '--experimental-wasm-modules',
    '$root/build/smoke.mjs',
  ]);
  return (res.stdout as String, res.stderr as String, res.exitCode);
}

Future<bool> _pollHealth() async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      final res = await Process.run('curl', [
        '-sS',
        '--max-time',
        '5',
        'http://127.0.0.1:8787/health',
      ]);
      if (res.exitCode == 0 && (res.stdout as String).contains('dart2wasm')) {
        final body = res.stdout as String;
        stdout.writeln('PASS: workerd served the Dart handler:\n$body');
        return true;
      }
    } catch (_) {
      // server not up yet
    }
    stdout.write('.');
  }
  stderr.writeln('\nFAIL: /health never returned the expected body');
  return false;
}
