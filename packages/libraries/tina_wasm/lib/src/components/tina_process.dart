// ignore_for_file: type=warning
/// The `tina:process` host interface: the engine's process port
/// (`tina_core.ProcessPort`) served by the host, because WASI has no
/// process spawn. Spec: docs/tina_process.md.
///
/// The access profile travels with every request; the host evaluates it
/// before any process exists and is the only side that can spawn. An
/// `ask` verdict returns to the engine as an approval request it answers
/// with `respond` - the host cannot call back into a blocked guest.
library;

import r'package:wasm_components/wasm_components.dart' as i0;

import r'dart:typed_data' as i1;

abstract interface class Types {}

/// The policy verdicts the engine sees. Refusal is an outcome with a
/// reason to surface, not an error.
sealed class TypesOutcome {
  const TypesOutcome._();
  const factory TypesOutcome.started(
    ({int id, Stream<i1.Uint8List> stdout, Stream<i1.Uint8List> stderr})
    payload,
  ) = TypesOutcomeStarted;
  const factory TypesOutcome.approval(
    ({int id, String command, String reason}) payload,
  ) = TypesOutcomeApproval;
  const factory TypesOutcome.denied(String payload) = TypesOutcomeDenied;
}

final class TypesOutcomeStarted extends TypesOutcome {
  final ({int id, Stream<i1.Uint8List> stdout, Stream<i1.Uint8List> stderr})
  payload;
  const TypesOutcomeStarted(this.payload) : super._();
}

final class TypesOutcomeApproval extends TypesOutcome {
  final ({int id, String command, String reason}) payload;
  const TypesOutcomeApproval(this.payload) : super._();
}

final class TypesOutcomeDenied extends TypesOutcome {
  final String payload;
  const TypesOutcomeDenied(this.payload) : super._();
}

/// Host-side failure (missing binary, bad cwd, ...): a message the
/// engine can surface verbatim, never a raw OS error.
sealed class TypesError {
  const TypesError._();
  const factory TypesError.message(String payload) = TypesErrorMessage;
}

final class TypesErrorMessage extends TypesError {
  final String payload;
  const TypesErrorMessage(this.payload) : super._();
}

/// How one command-pattern rule judges a command line.
enum TypesVerdict { allow, deny, ask }

/// How the process ended: an exit code, or termination by `signal`.
sealed class TypesExit {
  const TypesExit._();
  const factory TypesExit.code(int payload) = TypesExitCode;
  const factory TypesExit.signal(int payload) = TypesExitSignal;
}

final class TypesExitCode extends TypesExit {
  final int payload;
  const TypesExitCode(this.payload) : super._();
}

final class TypesExitSignal extends TypesExit {
  final int payload;
  const TypesExitSignal(this.payload) : super._();
}

abstract interface class Process {
  /// Ask the host to run `req`. The profile is evaluated first: allow
  /// starts the child, deny refuses with the rule, ask (or no match)
  /// returns an approval request the engine must answer.
  Future<i0.Result<TypesOutcome, TypesError>> spawn({
    required ({
      List<String> argv,
      i0.Option<String> cwd,
      List<(String, String)> env,
      i0.Option<List<int>> stdin,
      ({List<({String pattern, TypesVerdict verdict})> rules}) profile,
    })
    req,
  });

  /// Answer an approval request. `allow` spawns now and reports
  /// `started`; anything else refuses the spawn.
  Future<i0.Result<TypesOutcome, TypesError>> respond({
    required int approval,
    required bool allow,
  });

  /// Resolve when the process exits, and reap it. Every started
  /// process is eventually waited.
  Future<i0.Result<TypesExit, TypesError>> wait({required int id});

  /// Terminate the process (SIGKILL on POSIX hosts). Idempotent.
  Future<i0.Result<void, TypesError>> kill({required int id});
}
