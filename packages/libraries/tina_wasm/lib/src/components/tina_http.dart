// ignore_for_file: type=warning
/// The `tina:http` host interface: the engine's HTTP port
/// (`tina_core.HttpClientPort`) served by the host instead of `dart:io`.
///
/// The host enforces the capability document it was launched with
/// (`docs/capability_merger.md`): the network domain entries are the
/// allowlist. A request to an allowed domain proceeds; an unknown domain
/// returns an approval request the engine answers with `respond` after
/// its approval flow - the same round-trip `tina:process` uses, because
/// the host cannot call back into a blocked guest. `widen` (the
/// `tina:policy` interface) makes a remembered domain grant stick for the
/// rest of the run.
///
/// One function covers the port's POST and GET: the method travels in the
/// request. The response head (status + headers) arrives first; the body
/// is a component-model byte stream the guest reads incrementally, paired
/// with a future resolving once the whole body has been delivered - the
/// same shape as `wasi:cli/stdin.read-via-stream`, so guests lower it
/// with the stream/future machinery they already use for stdio.
///
/// 1.1.0: `send` returns an outcome (`sent` / `approval` / `denied`) and
/// `respond` answers an approval, mirroring `tina:process@1.1.0`.
library;

import r'package:wasm_components/wasm_components.dart' as i0;

import r'dart:typed_data' as i1;

abstract interface class Types {}

/// Why a request failed before any body: a host-side message, never a
/// raw OS error, so guests can surface it verbatim.
sealed class TypesError {
  const TypesError._();
  const factory TypesError.message(String payload) = TypesErrorMessage;
}

final class TypesErrorMessage extends TypesError {
  final String payload;
  const TypesErrorMessage(this.payload) : super._();
}

/// The policy verdicts the engine sees. Refusal is an outcome with a
/// reason to surface, not an error.
sealed class TypesOutcome {
  const TypesOutcome._();
  const factory TypesOutcome.sent(
    ({
      ({int status, List<(String, String)> headers}) head,
      Stream<i1.Uint8List> body,
      Future<i0.Result<void, TypesError>> delivered,
    })
    payload,
  ) = TypesOutcomeSent;
  const factory TypesOutcome.approval(
    ({int id, String url, String reason}) payload,
  ) = TypesOutcomeApproval;
  const factory TypesOutcome.denied(String payload) = TypesOutcomeDenied;
}

final class TypesOutcomeSent extends TypesOutcome {
  final ({
    ({int status, List<(String, String)> headers}) head,
    Stream<i1.Uint8List> body,
    Future<i0.Result<void, TypesError>> delivered,
  })
  payload;
  const TypesOutcomeSent(this.payload) : super._();
}

final class TypesOutcomeApproval extends TypesOutcome {
  final ({int id, String url, String reason}) payload;
  const TypesOutcomeApproval(this.payload) : super._();
}

final class TypesOutcomeDenied extends TypesOutcome {
  final String payload;
  const TypesOutcomeDenied(this.payload) : super._();
}

abstract interface class Client {
  /// Issue `req`. The domain allowlist is evaluated before anything is
  /// sent: an allowed domain completes when the response head is
  /// available (see `sent`); an unknown domain returns an approval
  /// request the engine must answer.
  Future<i0.Result<TypesOutcome, TypesError>> send({
    required ({
      String method,
      String url,
      List<(String, String)> headers,
      i0.Option<List<int>> body,
    })
    req,
  });

  /// Answer a parked approval. `allow` sends the parked request now and
  /// reports the outcome; anything else refuses it.
  Future<i0.Result<TypesOutcome, TypesError>> respond({
    required int approval,
    required bool allow,
  });
}
