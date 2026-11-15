/// Detached ed25519 entry signatures (scheme `ed25519-v1`).
///
/// The signed payload is the entry object without its `signature` field,
/// canonically serialized (see [canonicalJson]). The signature is the
/// 64-byte ed25519 signature over that payload, base64 (standard, padded).
/// The verifying key comes from the client config (pinned), never from the
/// fetched document.
import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart';

import 'canonical_json.dart';

/// Reconstructs the canonical signed payload of a parsed entry.
Uint8List signedPayload(Map<String, Object?> entry) =>
    utf8.encode(canonicalJson(_withoutSignature(entry)));

Map<String, Object?> _withoutSignature(Map<String, Object?> entry) =>
    Map.fromEntries(
        entry.entries.where((e) => e.key != 'signature').map((e) => MapEntry(e.key, e.value)));

/// Verifies a fetched entry against the pinned public key (raw 32 bytes).
/// Throws [SignatureVerificationError] on any mismatch.
void verifyEntrySignature(
    Map<String, Object?> entry, Uint8List pinnedPublicKey) {
  final signatureField = entry['signature'];
  if (signatureField is! Map<String, Object?>) {
    throw const SignatureVerificationError('entry has no signature field');
  }
  final scheme = signatureField['scheme'];
  if (scheme != 'ed25519-v1') {
    throw SignatureVerificationError('unknown signature scheme: $scheme');
  }
  final signatureText = signatureField['signature'];
  if (signatureText is! String) {
    throw const SignatureVerificationError('signature.signature missing');
  }
  final Uint8List signature;
  try {
    signature = Uint8List.fromList(base64.decode(signatureText));
  } on FormatException catch (e) {
    throw SignatureVerificationError('malformed signature encoding: $e');
  }
  if (signature.length != 64) {
    throw SignatureVerificationError(
        'signature must be 64 bytes, got ${signature.length}');
  }
  final payload = signedPayload(entry);
  final publicKey = PublicKey(pinnedPublicKey);
  if (!verify(publicKey, payload, signature)) {
    throw const SignatureVerificationError(
        'signature verification failed against the pinned key');
  }
}

class SignatureVerificationError implements Exception {
  const SignatureVerificationError(this.message);
  final String message;

  @override
  String toString() => 'SignatureVerificationError: $message';
}
