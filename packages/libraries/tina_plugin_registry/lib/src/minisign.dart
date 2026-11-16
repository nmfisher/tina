/// Pure-Dart minisign signature verification (the index-level signature
/// for the static registry site: `registry.json` + `registry.json.minisign`).
///
/// Format (jedisct1/minisign, validated against the real tool — see
/// test/fixtures/minisign_*):
/// - public key file: `untrusted comment: ...\n<base64>\n` where base64
///   decodes to 42 bytes: algorithm tag 'Ed' (2), key id (8), ed25519
///   public key (32).
/// - signature file: `untrusted comment: ...\n<base64>\n[trusted
///   comment: ...\n<base64>\n]` where the first base64 decodes to 74
///   bytes: algorithm tag (2), key id (8), ed25519 signature (64).
/// - the registry signs in minisign's LEGACY format (`minisign -S -l`):
///   tag 'Ed', the signature a raw ed25519 over the message bytes (the
///   trailing trusted-comment signature is display text; the registry
///   trusts the content signature only). The tool's newer default
///   (prehashed, tag 'ED') is refused with a re-sign instruction —
///   `minisign -V` accepts legacy signatures everywhere, so the format
///   costs nothing on the verification-tool side.
/// - the signature's key id must equal the pinned key's key id.
///
/// The verifying key is pinned by the caller (the client's config /
/// built-in default), never read from the fetched document.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// Verifies [signatureFile] (the full `.minisig` contents) over
/// [message] against the key in [minisignKeyFileOrBody] (the full public
/// key file text or its bare base64 body). Throws [MinisignError] on any
/// mismatch.
void verifyMinisign({
  required List<int> message,
  required String signatureFile,
  required String minisignKeyFileOrBody,
}) {
  final key = _parseKey(minisignKeyFileOrBody);
  final signature = _parseSignature(signatureFile);
  if (!listEquals(signature.keyId, key.keyId)) {
    throw const MinisignError(
        'minisign signature key id does not match the pinned key');
  }
  if (!ed.verify(ed.PublicKey(key.publicKey), Uint8List.fromList(message),
      signature.signature)) {
    throw const MinisignError(
        'minisign signature verification failed against the pinned key');
  }
}

/// Extracts the raw 32-byte ed25519 public key from a minisign public
/// key file (both lines) or its bare base64 body.
Uint8List minisignPublicKey(String keyFileOrBody) =>
    _parseKey(keyFileOrBody).publicKey;

class _MinisignKey {
  const _MinisignKey(this.publicKey, this.keyId);
  final Uint8List publicKey;
  final Uint8List keyId;
}

class _MinisignSignature {
  const _MinisignSignature(this.signature, this.keyId);
  final Uint8List signature;
  final Uint8List keyId;
}

_MinisignKey _parseKey(String keyFileOrBody) {
  final decoded = _decodeBody(keyFileOrBody, 42,
      const [0x45, 0x64], 'minisign public key');
  return _MinisignKey(
    Uint8List.sublistView(decoded, 10),
    Uint8List.sublistView(decoded, 2, 10),
  );
}

_MinisignSignature _parseSignature(String signatureFile) {
  final lines = signatureFile
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length < 2) {
    throw const MinisignError(
        'minisign signature file must have a comment and a signature line');
  }
  final decoded = _decodeSignatureBody(lines[1]);
  return _MinisignSignature(
    Uint8List.sublistView(decoded, 10),
    Uint8List.sublistView(decoded, 2, 10),
  );
}

Uint8List _decodeSignatureBody(String body) {
  final decoded = _base64DecodeOrThrow(body, 'minisign signature');
  if (decoded.length != 74) {
    throw MinisignError(
        'minisign signature must decode to 74 bytes, got ${decoded.length}');
  }
  if (decoded[0] == 0x45 && decoded[1] == 0x44) {
    // 'ED': the prehashed default of minisign >= 0.11.
    throw const MinisignError(
        'prehashed minisign signatures are not supported; re-sign the '
        "index with the legacy format: minisign -S -l -m registry.json "
        '-x registry.json.minisig');
  }
  if (decoded[0] != 0x45 || decoded[1] != 0x64) {
    throw const MinisignError(
        'minisign signature has an unknown algorithm tag');
  }
  return decoded;
}

Uint8List _base64DecodeOrThrow(String body, String what) {
  try {
    return Uint8List.fromList(base64.decode(body));
  } on FormatException {
    throw MinisignError('$what is not valid base64');
  }
}

Uint8List _decodeBody(
    String text, int expectedLength, List<int> tag, String what) {
  final body = _base64Body(text);
  final Uint8List decoded;
  try {
    decoded = Uint8List.fromList(base64.decode(body));
  } on FormatException {
    throw MinisignError('$what is not valid base64');
  }
  if (decoded.length != expectedLength ||
      decoded[0] != tag[0] ||
      decoded[1] != tag[1]) {
    throw MinisignError('$what must decode to $expectedLength bytes with '
        'the minisign algorithm tag');
  }
  return decoded;
}

/// The base64 payload line of a minisign file: either the whole input is
/// already a bare base64 body, or the second non-empty line is.
String _base64Body(String text) {
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length == 1) return lines.single;
  if (lines.length >= 2) return lines[1];
  throw const MinisignError('empty minisign key/signature input');
}

bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class MinisignError implements Exception {
  const MinisignError(this.message);
  final String message;

  @override
  String toString() => 'MinisignError: $message';
}
