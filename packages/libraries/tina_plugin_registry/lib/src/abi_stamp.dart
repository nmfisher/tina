/// The plugin component's `tina.embedder-abi` custom section: a one-section
/// stamp appended by the fixture build (`stamp_abi.py`) and preflighted by
/// the host loader (`verify_embedder_abi`). Payload: a little-endian u32
/// ABI version (currently 1).
import 'dart:convert' show latin1;
import 'dart:typed_data';

const String abiSectionName = 'tina.embedder-abi';

/// The ABI version the running loader accepts (plugin_loader.rs
/// `EMBEDDER_ABI_VERSION`).
const int embedderAbiVersion = 1;

/// Reads the stamp version from component bytes, or throws if the section
/// is missing, duplicated, malformed, or the wasm is not a v1 component.
int readEmbedderAbiStamp(Uint8List bytes) {
  const header = [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
  for (var i = 0; i < header.length; i++) {
    if (bytes[i] != header[i]) {
      throw const AbiStampError('not a version-1 Wasm component');
    }
  }
  var pos = header.length;
  final found = <(int, int)>[]; // (payload start, section end)
  while (pos < bytes.length) {
    final sectionId = bytes[pos];
    pos += 1;
    final (length, body) = _readUleb(bytes, pos);
    final end = body + length;
    if (end > bytes.length) {
      throw const AbiStampError('section exceeds file');
    }
    if (sectionId == 0) {
      final (nameLength, namePos) = _readUleb(bytes, body);
      final nameEnd = namePos + nameLength;
      if (nameEnd > end) {
        throw const AbiStampError('custom section name exceeds section');
      }
      final name = latin1.decode(bytes.sublist(namePos, nameEnd));
      if (name == abiSectionName) {
        found.add((nameEnd, end));
      }
    }
    pos = end;
  }
  if (found.length > 1) {
    throw const AbiStampError('duplicate tina.embedder-abi section');
  }
  if (found.isEmpty) {
    throw const AbiStampError('missing tina.embedder-abi section');
  }
  final (payload, sectionEnd) = found.single;
  if (sectionEnd - payload != 4) {
    throw const AbiStampError('tina.embedder-abi payload must be exactly four bytes');
  }
  return bytes[payload] |
      (bytes[payload + 1] << 8) |
      (bytes[payload + 2] << 16) |
      (bytes[payload + 3] << 24);
}

/// The full byte-level check the client runs before installing: the stamp
/// must exist and match the loader's accepted version.
void requireEmbedderAbi(Uint8List bytes) {
  final version = readEmbedderAbiStamp(bytes);
  if (version != embedderAbiVersion) {
    throw AbiStampError(
        'tina.embedder-abi version $version, engine accepts $embedderAbiVersion');
  }
}

(int, int) _readUleb(Uint8List data, int pos) {
  var value = 0;
  var shift = 0;
  for (var step = 0; step < 5; step++) {
    if (pos >= data.length) {
      throw const AbiStampError('truncated section length');
    }
    final byte = data[pos];
    pos += 1;
    value |= (byte & 0x7f) << shift;
    shift += 7;
    if (byte & 0x80 == 0) {
      if (shift == 35 && byte > 0x0f) {
        throw const AbiStampError('overflowing section length');
      }
      return (value, pos);
    }
  }
  throw const AbiStampError('oversized section length');
}

class AbiStampError implements Exception {
  const AbiStampError(this.message);
  final String message;

  @override
  String toString() => 'AbiStampError: $message';
}
