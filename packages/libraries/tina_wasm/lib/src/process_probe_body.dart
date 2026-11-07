/// The stage-4 process exit-test probe: one tina-shaped run through the
/// engine's process port.
///
/// The same body runs natively (an `IoProcessPort` over `dart:io`,
/// policy evaluated engine-side) and under wasmtime (a `WasmProcessPort`
/// over the `tina:process` host import, policy enforced host-side):
/// it runs `git status` through the port, feeds a child's stdin, merges
/// environment overrides, routes an approval-required command through
/// tina_mode's decision pipeline, and shows a denial blocking execution
/// before anything runs. Everything it reports is deterministic, so the
/// recorded output of the two runs must be identical, line for line -
/// including the approval requests crossing the wasm boundary and the
/// refusal reasons coming back.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_mode/authorization.dart';
import 'package:tina_mode/mode.dart' show PermissionMode;
import 'package:tina_wasm/src/probe_body.dart';

/// The profile both probes send: `git status` is allowed, `rm ...` is
/// denied, and everything else asks - tina_mode's default route for an
/// unremembered command.
const processProbeProfile = ProcessAccessProfile([
  ProcessRule('git status', ProcessVerdict.allow),
  ProcessRule('rm .*', ProcessVerdict.deny),
]);

/// The engine-side of the approval round-trip. Under wasm the HOST
/// evaluated the profile and handed back an `ask` outcome; routing it
/// through tina_mode's policy table is the engine's existing approval
/// flow, and the (programmed) human answer returns to the host with
/// `respond`.
Future<bool> processProbeApprover(
  ProcessApprovalRequest request,
  ProbeRecorder recorder,
) async {
  recorder.string('approval requested: ${request.command}');
  recorder.string('host reason: ${request.reason}');
  final authorization = AuthorizationRequest(
    requirements: [
      AccessRequirement(
        AccessCapability.execute,
        request.command,
        workspace: true,
      ),
    ],
  );
  final resolution = resolveAuthorization(authorization, PermissionMode.ask);
  recorder.string('tina_mode route: ${resolution.route.name}');
  recorder.string('tina_mode reason: ${resolution.reason}');
  // The human in this probe always grants; the answer crosses back and
  // only then does the host spawn.
  return true;
}

/// Runs the probe. [processes] is the port under test, already wired to
/// [processProbeApprover]; the working directory (the preopened
/// workspace under wasm, the cwd natively) is where `git status` runs.
Future<void> runProcessProbe({
  required ProcessPort processes,
  required ProbeRecorder recorder,
  String workingDirectory = '.',
}) async {
  // (a) A real command through the boundary, allowed by profile rule 0.
  recorder.string('probe: process git status');
  final git = await processes.run(
    'git',
    ['status'],
    workingDirectory: workingDirectory,
  );
  recorder.integer(git.exitCode);
  final gitLines = git.stdout.split('\n')..removeLast();
  for (final line in gitLines) {
    recorder.string('git| $line');
  }
  recorder.string('git stderr empty: ${git.stderr.isEmpty}');

  // (b) stdin bytes and environment overrides, on commands no rule
  // covers: every one of these crosses the approval boundary first.
  recorder.string('probe: approval round-trip');
  final cat = await processes.run('cat', [], stdin: 'piped stdin\n');
  recorder.string('cat stdin round-trip: ${cat.stdout}');
  recorder.integer(cat.exitCode);

  final env = await processes.run(
    'printenv',
    ['TINA_PROCESS_PROBE'],
    environment: {'TINA_PROCESS_PROBE': 'env-override-works'},
  );
  recorder.string('printenv: ${env.stdout}');
  recorder.integer(env.exitCode);

  // (c) A denied command: the rule blocks the spawn before any process
  // exists, and the reason surfaces to the engine.
  recorder.string('probe: denial');
  try {
    await processes.run('rm', ['-rf', '/tmp/tina-process-probe-denied']);
    recorder.string('denial: NOT REFUSED (bug)');
  } on ProcessRefusedException catch (error) {
    recorder.string('denied: ${error.reason}');
  }
}
