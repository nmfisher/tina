/// Fetches the registry index and artifacts. The default transport is
/// dart:io HttpClient; tests inject a fetch function.
library tina_plugin_registry;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'entry.dart';

typedef FetchBytes = Future<Uint8List> Function(String url);

class RegistryClient {
  RegistryClient({required this.url, FetchBytes? fetch})
      : _fetch = fetch ?? _defaultFetch;

  final String url;
  final FetchBytes _fetch;

  /// Fetches and parses index.json. Returns the raw decoded map plus the
  /// parsed entries.
  Future<RegistryIndex> fetchIndex() async {
    final bytes = await fetchIndexRaw();
    final decoded = json.decode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const RegistryClientError('index.json must be a JSON object');
    }
    if (decoded['entries'] is! List) {
      throw const RegistryClientError('index.json lacks an entries array');
    }
    final entries = <ParsedEntry>[];
    for (final entry in decoded['entries'] as List) {
      if (entry is Map<String, Object?>) {
        entries.add(parseEntry(entry));
      }
    }
    return RegistryIndex(
      updated: decoded['updated'] is String
          ? decoded['updated'] as String
          : '',
      entries: entries,
    );
  }

  /// The raw index bytes (the signed entry objects ride inside).
  Future<Uint8List> fetchIndexRaw() =>
      _fetch(_join(url, 'index.json'));

  /// Fetches an artifact by its content address.
  Future<Uint8List> fetchBlob(String sha256) =>
      _fetch(_join(url, 'blobs/$sha256.wasm'));

  String _join(String base, String path) =>
      base.endsWith('/') ? '$base$path' : '$base/$path';

  static Future<Uint8List> _defaultFetch(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw RegistryClientError(
            'GET $url failed: HTTP ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}

class RegistryIndex {
  const RegistryIndex({required this.updated, required this.entries});

  final String updated;
  final List<ParsedEntry> entries;

  /// Latest entry for a name (semver-aware enough: string order on the
  /// version core, documented; the installer prefers an exact version).
  ParsedEntry? latest(String name) {
    final matches = entries.where((e) => e.name == name).toList()
      ..sort((a, b) => _compareVersions(a.version, b.version));
    return matches.isEmpty ? null : matches.last;
  }

  ParsedEntry? exact(String name, String version) {
    for (final entry in entries) {
      if (entry.name == name && entry.version == version) return entry;
    }
    return null;
  }
}

int _compareVersions(String a, String b) {
  List<int> core(String v) => v
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final aCore = core(a);
  final bCore = core(b);
  for (var i = 0; i < 3; i++) {
    final av = i < aCore.length ? aCore[i] : 0;
    final bv = i < bCore.length ? bCore[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return a.compareTo(b);
}

class RegistryClientError implements Exception {
  const RegistryClientError(this.message);
  final String message;

  @override
  String toString() => 'RegistryClientError: $message';
}
