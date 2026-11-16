/// The static-site registry index: `registry.json` + `registry.json.minisig`
/// + `plugins/<name>-<version>.component.wasm`, the layout the public
/// registry site serves (Cloudflare Pages; see tool/build_registry_site.sh).
///
/// Trust model: the whole index is authenticated by ONE minisign
/// signature over registry.json's bytes against a key pinned in the
/// client (the tina release minisign key by default — the same root
/// install.sh pins). Entries inside the signed index therefore need no
/// per-entry signature; when an entry still carries one (the
/// content-addressed publisher flow), it is verified too. Artifact
/// integrity is sha256 + size against the signed index's declared
/// values. Provenance is not permission: the manifest-consent flow runs
/// unchanged after verification.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'minisign.dart';
import 'registry_client.dart'
    show FetchBytes, RegistryClientError, defaultFetchBytes;

/// The index format this client understands. A registry.json declaring
/// anything else is a version skew: refuse with a clear message rather
/// than guessing at a newer format.
const int siteRegistryFormat = 1;

class SiteRegistry {
  SiteRegistry({
    required this.indexUrl,
    required this.minisignKeyFileOrBody,
    FetchBytes? fetch,
  }) : _fetch = fetch ?? defaultFetchBytes;

  /// The site root (registry.json is fetched from `$indexUrl/registry.json`).
  final String indexUrl;

  /// The pinned minisign public key (full key file text or bare base64
  /// body). Never fetched.
  final String minisignKeyFileOrBody;

  final FetchBytes _fetch;

  /// Fetches registry.json + registry.json.minisig, verifies the
  /// signature against the pinned key, and checks the format version.
  Future<VerifiedSiteIndex> fetchIndex() async {
    final indexBytes = await _fetch(_join('registry.json'));
    final signature = utf8.decode(await _fetch(_join('registry.json.minisig')),
        allowMalformed: true);

    try {
      verifyMinisign(
        message: indexBytes,
        signatureFile: signature,
        minisignKeyFileOrBody: minisignKeyFileOrBody,
      );
    } on MinisignError catch (error) {
      throw RegistryClientError(
          'registry index signature rejected: ${error.message}');
    }

    final Object? decoded;
    try {
      decoded = json.decode(utf8.decode(indexBytes));
    } on FormatException {
      throw const RegistryClientError('registry.json is not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const RegistryClientError('registry.json must be a JSON object');
    }
    final format = decoded['registry_format'];
    if (format is! int) {
      throw const RegistryClientError(
          'registry.json lacks an integer registry_format');
    }
    if (format != siteRegistryFormat) {
      throw RegistryClientError(
          'registry index format $format is newer than this client '
          '(understands $siteRegistryFormat); update tina');
    }
    if (decoded['entries'] is! List) {
      throw const RegistryClientError('registry.json lacks an entries array');
    }
    return VerifiedSiteIndex(
      format: format,
      updated: decoded['updated'] is String ? decoded['updated'] as String : '',
      rawEntries: (decoded['entries'] as List)
          .whereType<Map<String, Object?>>()
          .toList(),
    );
  }

  /// Fetches an entry's artifact by its declared site-relative path
  /// (`plugins/<name>-<version>.component.wasm`). The sha256/size checks
  /// happen in [installVerified] against the signed index's values.
  Future<Uint8List> fetchArtifact(Map<String, Object?> entry) async {
    final artifact = entry['artifact'];
    if (artifact is! Map<String, Object?>) {
      throw const RegistryClientError('entry has no artifact table');
    }
    final path = artifact['path'];
    if (path is! String || path.isEmpty) {
      throw const RegistryClientError('entry.artifact.path missing');
    }
    // The signed index is trusted, but the guard is free: a path leaving
    // the site root is malformed, not merely suspicious.
    if (path.startsWith('/') ||
        path.contains('..') ||
        path.contains('\\') ||
        !path.startsWith('plugins/')) {
      throw RegistryClientError(
          'entry.artifact.path must be a site-relative plugins/ path, '
          'got "$path"');
    }
    return _fetch(_join(path));
  }

  String _join(String path) =>
      indexUrl.endsWith('/') ? '$indexUrl$path' : '$indexUrl/$path';
}

class VerifiedSiteIndex {
  const VerifiedSiteIndex({
    required this.format,
    required this.updated,
    required this.rawEntries,
  });

  final int format;
  final String updated;
  final List<Map<String, Object?>> rawEntries;

  /// The latest entry for [name], or null when the index has no such
  /// plugin (version ordering: plain string compare is enough while
  /// versions are 0.x).
  Map<String, Object?>? latest(String name) {
    final matches = rawEntries
        .where((e) => e['name'] == name && _downloadable(e))
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => '${a['version']}'.compareTo('${b['version']}'));
    return matches.last;
  }

  Map<String, Object?>? exact(String name, String version) {
    for (final entry in rawEntries) {
      if (equalsEntry(entry, name, version) && _downloadable(entry)) {
        return entry;
      }
    }
    return null;
  }

  /// Whether an entry is downloadable (catalog-only entries — the
  /// binary-embedded plugins — have no artifact and say so in `source`).
  static bool downloadable(Map<String, Object?> entry) => _downloadable(entry);

  static bool equalsEntry(Map<String, Object?> entry, String name, String version) =>
      entry['name'] == name && entry['version'] == version;

  static bool _downloadable(Map<String, Object?> entry) =>
      entry['artifact'] != null && entry['source'] != 'included';
}

