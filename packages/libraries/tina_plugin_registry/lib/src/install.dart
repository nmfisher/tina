/// The install orchestration: resolve -> fetch -> verify (signature,
/// sha256, embedded ABI stamp, declared stamps) -> consent -> cache ->
/// config record.
library tina_plugin_registry;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'abi_stamp.dart';
import 'consent.dart';
import 'entry.dart';
import 'plugin_cache.dart';
import 'registry_client.dart';
import 'signature.dart';

/// Verifies a fetched entry + artifact bytes end to end. Throws on any
/// mismatch; returns the verified grants to record.
VerifyResult verifyArtifact({
  required Map<String, Object?> entry,
  required Uint8List artifactBytes,
  required Uint8List pinnedPublicKey,
}) {
  // 1. Signature over the canonical entry against the pinned key.
  verifyEntrySignature(entry, pinnedPublicKey);
  final parsed = parseEntry(entry);

  // 2. Integrity: sha256 over the bytes equals the declared digest.
  final digest = sha256.convert(artifactBytes).toString();
  if (digest != parsed.sha256) {
    throw VerificationError(
        'sha256 mismatch: declared ${parsed.sha256}, artifact $digest');
  }
  if (artifactBytes.length != parsed.size) {
    throw VerificationError(
        'size mismatch: declared ${parsed.size}, artifact ${artifactBytes.length}');
  }

  // 3. The embedded stamp must match the running loader's acceptance.
  requireEmbedderAbi(artifactBytes);

  // 4. The declared stamps must match the engine's known world versions.
  final abi = entry['abi'];
  if (abi is Map<String, Object?>) {
    final declared = abi['embedder_abi'];
    if (declared is int && declared != embedderAbiVersion) {
      throw VerificationError(
          'declared embedder_abi $declared, engine accepts $embedderAbiVersion');
    }
    final world = abi['world'];
    if (world is String && !_knownWorlds.contains(world)) {
      throw VerificationError(
          'declared world $world is not one this engine loads: '
          '$_knownWorlds');
    }
  }

  return VerifyResult(parsed: parsed, digest: digest);
}

/// The worlds the engine's loader accepts today (plugin_loader.rs
/// `PLUGIN_WORLD_VERSION` + the production prompt adapter's import).
const Set<String> _knownWorlds = {
  'tina:plugin-probe/plugin@0.1.0',
  'tina:plugin-host/session@0.1.0',
};

class VerifyResult {
  const VerifyResult({required this.parsed, required this.digest});

  final ParsedEntry parsed;
  final String digest;
}

/// Installs a verified entry: consent -> cache -> config.
Future<InstallOutcome> installVerified({
  required Map<String, Object?> entry,
  required Uint8List artifactBytes,
  required Uint8List pinnedPublicKey,
  required PluginCache cache,
  required RegistryConfig config,
  required ConsentFlow consent,
  required bool activate,
}) async {
  final verified =
      verifyArtifact(entry: entry, artifactBytes: artifactBytes, pinnedPublicKey: pinnedPublicKey);
  final parsed = verified.parsed;

  final outcome = consent(parsed);
  if (outcome.aborted) {
    return InstallOutcome(
        name: parsed.name,
        version: parsed.version,
        aborted: true,
        abortReason: outcome.abortReason);
  }

  await cache.install(
    name: parsed.name,
    version: parsed.version,
    componentBytes: artifactBytes,
    entry: entry,
    grants: outcome.grantedStrings(),
    // Denied capabilities are recorded as grant strings too, so the
    // decision log is one format throughout.
    deniedIds: outcome.decisions
        .where((d) => !d.granted)
        .map((d) => d.grantString)
        .toList(),
  );

  final data = config.read();
  final installedRef = '${parsed.name}@${parsed.version}';
  final installed = data.installed.where((r) => !r.startsWith('${parsed.name}@')).toList()
    ..add(installedRef);
  data.installed = installed;
  if (activate || data.active == null) {
    data.active = parsed.name;
  }
  config.write(data);

  return InstallOutcome(
    name: parsed.name,
    version: parsed.version,
    grants: outcome.grantedStrings(),
    denied: outcome.decisions
        .where((d) => !d.granted)
        .map((d) => d.grantString)
        .toList(),
    unenforced: outcome.decisions
        .where((d) => d.granted && !d.enforcedByHost)
        .map((d) => d.grantString)
        .toList(),
    componentPath: cache.componentFile(parsed.name, parsed.version).path,
    aborted: false,
  );
}

typedef ConsentFlow = ConsentOutcome Function(ParsedEntry entry);

class InstallOutcome {
  const InstallOutcome({
    required this.name,
    required this.version,
    this.grants = const [],
    this.denied = const [],
    this.unenforced = const [],
    this.componentPath,
    required this.aborted,
    this.abortReason,
  });

  final String name;
  final String version;
  final List<String> grants;
  final List<String> denied;
  final List<String> unenforced;
  final String? componentPath;
  final bool aborted;
  final String? abortReason;
}

class VerificationError implements Exception {
  const VerificationError(this.message);
  final String message;

  @override
  String toString() => 'VerificationError: $message';
}

/// Resolves an entry from the index (exact `name@version` or latest) and
/// fetches the artifact bytes.
Future<(Map<String, Object?>, Uint8List)> resolveAndFetch(
    RegistryClient client, String specifier) async {
  final index = await client.fetchIndex();
  String? name;
  String? version;
  final at = specifier.lastIndexOf('@');
  if (at > 0) {
    name = specifier.substring(0, at);
    version = specifier.substring(at + 1);
  } else {
    name = specifier;
  }
  final entry = version == null ? index.latest(name) : index.exact(name, version);
  if (entry == null) {
    throw RegistryClientError('no registry entry for $specifier');
  }
  final bytes = await client.fetchBlob(entry.sha256);
  // The signed entry object itself (from the index) rides along.
  final raw = index.entries.indexOf(entry);
  final entryObject = await _entryObject(client, raw, entry);
  return (entryObject, bytes);
}

/// The client needs the full signed entry object, not just the parsed
/// projection. Refetching the index as raw JSON keeps one fetch in the
/// common case.
Future<Map<String, Object?>> _entryObject(
    RegistryClient client, int indexPosition, dynamic _) async {
  final bytes = await client.fetchIndexRaw();
  final decoded = json.decode(utf8.decode(bytes));
  final entries = decoded['entries'] as List;
  return Map<String, Object?>.from(entries[indexPosition] as Map);
}
