/// The native resume probe: the same assembly the `tina` CLI builds,
/// started with a stored session id and served over the pipes protocol —
/// the headless resume path the CLI's argument gate currently reserves
/// for the terminal (`--pipes cannot be combined with --resume`), while
/// the wasm engine resumes over pipes by construction. The assembly
/// itself is identical; this probe is the native reference the scenario
/// suite's persist+resume comparison drives.
///
///   dart run bin/native_resume_probe.dart --config CFG --store PATH \
///     --resume SESSION_ID [--cwd .]
library;

import 'dart:io' as io;

import 'package:tina/src/assembly.dart';
import 'package:tina/src/pipes.dart';

void main(List<String> arguments) async {
  String? arg(String name) => arguments.contains(name)
      ? arguments[arguments.indexOf(name) + 1]
      : null;
  final assembly = SessionAssembly.start(
    options: AssemblyOptions(
      configPath: arg('--config'),
      workingDirectory: arg('--cwd') ?? '.',
      storePath: arg('--store'),
      sessionId: arg('--resume'),
      yolo: arguments.contains('--yolo'),
      interactive: false,
      osSandbox: false,
      approvalChannel: 'tina/approvals-stream',
    ),
  );
  try {
    await runSessionPipes(assembly);
  } finally {
    await assembly.shutdown();
  }
  await io.stdout.flush();
}
