/// The native process port: `tina_core`'s [ProcessPort] over
/// `dart:io`'s `Process.run`, behind the process access profile.
///
/// With no profile this is a plain `Process.run` wrapper - the native
/// composition root's behavior is unchanged. With one, it evaluates the
/// profile exactly the way the wasm host does
/// ([evaluateProcessPolicy], whose reason strings are interface
/// contract, see wasm.dart's `tina:process` spec): refusals throw
/// before anything runs, and `ask` verdicts go through the configured
/// [ProcessApprover] - on the native side the same approval flow that
/// answers `tina_mode`'s command rules. The engine holds one policy;
/// where it is enforced only depends on where the spawn happens.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:tina_core/tina_core.dart';

final class IoProcessPort implements ProcessPort {
  IoProcessPort({ProcessAccessProfile? profile, ProcessApprover? approver})
    : _profile = profile,
      _approver = approver;

  final ProcessAccessProfile? _profile;
  final ProcessApprover? _approver;

  @override
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    if (_profile case final profile?) {
      final command = [executable, ...arguments].join(' ');
      final decision = evaluateProcessPolicy(profile, command);
      if (decision.verdict == ProcessVerdict.deny) {
        throw ProcessRefusedException(decision.reason!);
      }
      if (decision.verdict == ProcessVerdict.ask) {
        // The approval request crosses no boundary natively, but the
        // flow is the one that answers every `ask`: the configured
        // approver (tina_mode's decision pipeline, then the human).
        final approver = _approver;
        final allowed = approver == null
            ? false
            : await approver(
                ProcessApprovalRequest(
                  command: command,
                  reason: decision.reason ?? '',
                ),
              );
        if (!allowed) {
          throw const ProcessRefusedException(
            'the approval flow denied the command',
          );
        }
      }
    }
    // `Process.run` cannot feed stdin, so this is its body: start the
    // child, write and close stdin, drain both pipes, then await the
    // exit code - the wasm port does the same against the host streams.
    final process = await io.Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    if (stdin != null) {
      process.stdin.write(stdin);
      await process.stdin.flush();
      await process.stdin.close();
    }
    final decode = const Utf8Codec(allowMalformed: true);
    final drained = await Future.wait([
      process.stdout.transform(decode.decoder).join(),
      process.stderr.transform(decode.decoder).join(),
    ]);
    return ProcessRunResult(
      exitCode: await process.exitCode,
      stdout: drained[0],
      stderr: drained[1],
    );
  }
}
