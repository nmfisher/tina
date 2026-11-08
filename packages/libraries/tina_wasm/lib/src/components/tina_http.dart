// ignore_for_file: type=warning
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

abstract interface class Client {
  /// Issue `req`. The call is async: it completes when the response
  /// head is available, and hands back
  ///
  /// - the head (status + headers),
  /// - the body as a byte stream, in order, chunked as the network
  ///   delivers it, and
  /// - a future that resolves with an error when the body transfer
  ///   failed, and successfully once every body byte was delivered.
  ///
  /// Dropping the stream cancels the transfer.
  Future<
    i0.Result<
      (
        ({int status, List<(String, String)> headers}),
        Stream<i1.Uint8List>,
        Future<i0.Result<void, TypesError>>,
      ),
      TypesError
    >
  >
  send({
    required ({
      String method,
      String url,
      List<(String, String)> headers,
      i0.Option<List<int>> body,
    })
    req,
  });
}
