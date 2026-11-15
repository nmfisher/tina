/// Registry entry model + the canonical grant strings.
///
/// One manifest capability object ↔ one canonical grant string ↔ one
/// loader decision. The grant string encodes the capability's parameters:
/// `<id>` when parameterless, otherwise `<id>:<key>=<value>[,...]` with
/// keys and values sorted - byte-compatible with the Rust publisher's
/// encoder (`canonical_grant_string`).
import 'canonical_json.dart';

/// The capability ids the host understands today (`PLUGIN_GRANTS` in
/// policy.rs).
const Set<String> hostAcceptedGrants = {
  'session.read-context',
  'engine-service-import',
  'engine-service-call',
};

/// The consent surfaces from the design (section 4): recorded but not yet
/// enforced by the running host.
const Set<String> consentSurfaceIds = {'session-store', 'filesystem', 'network'};

/// Every capability id the publisher may emit and the installer accepts.
const Set<String> knownCapabilityIds = {...hostAcceptedGrants, ...consentSurfaceIds};

/// The canonical grant string for a parsed capability object.
String canonicalGrantString(Map<String, Object?> capability) {
  final id = capability['id'];
  if (id is! String || id.isEmpty) {
    throw const EntrySchemaError('capability without an id');
  }
  final params = <String>[];
  final keys = capability.keys.where((k) => k != 'id').toList()..sort();
  for (final key in keys) {
    if (key == 'required' || key == 'summary') continue;
    final value = capability[key];
    final encoded = value is String ? value : canonicalJson(value);
    params.add('$key=$encoded');
  }
  if (params.isEmpty) return id;
  return '$id:${params.join(',')}';
}

/// Whether the manifest capability is marked required (default false).
bool capabilityRequired(Map<String, Object?> capability) =>
    capability['required'] == true;

/// Parses and validates the entry's shape the installer depends on.
ParsedEntry parseEntry(Map<String, Object?> entry) {
  final name = entry['name'];
  final version = entry['version'];
  if (name is! String || name.isEmpty) {
    throw const EntrySchemaError('entry.name missing');
  }
  if (version is! String || version.isEmpty) {
    throw const EntrySchemaError('entry.version missing');
  }
  final artifact = entry['artifact'];
  if (artifact is! Map<String, Object?>) {
    throw const EntrySchemaError('entry.artifact missing');
  }
  final sha256 = artifact['sha256'];
  final size = artifact['size'];
  if (sha256 is! String || sha256.length != 64 || RegExp(r'[^0-9a-f]').hasMatch(sha256)) {
    throw const EntrySchemaError('entry.artifact.sha256 must be 64 lowercase hex');
  }
  if (size is! int || size < 0) {
    throw const EntrySchemaError('entry.artifact.size must be a non-negative integer');
  }
  final capabilities = entry['capabilities'];
  if (capabilities != null && capabilities is! List) {
    throw const EntrySchemaError('entry.capabilities must be an array');
  }
  final parsedCapabilities = <Map<String, Object?>>[];
  for (final capability in (capabilities ?? <Object?>[]) as List<Object?>) {
    if (capability is! Map<String, Object?>) {
      throw const EntrySchemaError('capability entries must be objects');
    }
    final id = capability['id'];
    if (id is! String) {
      throw const EntrySchemaError('capability without an id');
    }
    if (!knownCapabilityIds.contains(id)) {
      throw EntrySchemaError('unknown capability id: $id');
    }
    parsedCapabilities.add(capability);
  }
  return ParsedEntry(
    name: name,
    version: version,
    description: entry['description'] is String
        ? entry['description'] as String
        : '',
    sha256: sha256,
    size: size,
    blobPath: artifact['path'] is String
        ? artifact['path'] as String
        : 'blobs/$sha256.wasm',
    capabilities: parsedCapabilities,
  );
}

class ParsedEntry {
  const ParsedEntry({
    required this.name,
    required this.version,
    required this.description,
    required this.sha256,
    required this.size,
    required this.blobPath,
    required this.capabilities,
  });

  final String name;
  final String version;
  final String description;
  final String sha256;
  final int size;
  final String blobPath;
  final List<Map<String, Object?>> capabilities;

  /// The canonical grant strings of the whole manifest (the consent
  /// rendering order).
  List<String> grantStrings() =>
      capabilities.map(canonicalGrantString).toList();
}

class EntrySchemaError implements Exception {
  const EntrySchemaError(this.message);
  final String message;

  @override
  String toString() => 'EntrySchemaError: $message';
}
