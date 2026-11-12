/// The capability document: one compiled list of what the engine may do.
///
/// Schema (version 1), mirrored fail-closed by the host's Rust loader
/// (`pkg/tina_wasm_host/src/policy.rs` in wasm.dart; see
/// `docs/engine2-capability-merger.md` in the tina repository):
///
/// ```json
/// {
///   "version": 1,
///   "mode": "allow-edits",
///   "workspace": "/canonical/workspace",
///   "directories": {
///     "read":  [{"path": "...", "guest": "read-0", "origin": "..."}],
///     "write": [{"path": "...", "guest": ".",     "origin": "..."}]
///   },
///   "network": {
///     "allow_all": false,
///     "domains": [{"domain": "api.example.com", "origin": "..."}]
///   },
///   "commands": {
///     "default_verdict": "ask",
///     "rules": [{"pattern": "^git status$", "verdict": "allow", "origin": "..."}]
///   },
///   "plugins": {
///     "grants": [{"plugin": "tina/wasm-prompt", "grants": ["..."], "origin": "..."}]
///   },
///   "protected_paths": ["..."],
///   "preopens": [{"guest": ".", "host": "...", "access": "rw", "origin": "..."}]
/// }
/// ```
///
/// Every entry is explicit and traceable to its source through `origin`.
/// Decoding validates fail-closed: an unknown key, bad version, invalid
/// guest name or domain, uncompilable pattern, missing-or-non-canonical
/// path, or a `preopens` array that disagrees with the derivation from
/// the directory grants fails the whole document.
///
/// Paths are consumed as canonical host paths: this package has no
/// `dart:io` (the document also travels through the wasm engine), so
/// symlink resolution is the caller's job - the host re-canonicalizes on
/// load and refuses mismatches.
library;

import 'dart:convert';

/// The launch modes, named exactly as the JSON carries them.
enum CapabilityMode {
  ask('ask'),
  readOnly('read-only'),
  allowEdits('allow-edits'),
  auto('auto'),
  yolo('yolo');

  const CapabilityMode(this.json);

  final String json;

  static CapabilityMode parse(String value) {
    for (final mode in values) {
      if (mode.json == value) return mode;
    }
    throw CapabilityDocumentException(
        'capability document mode "$value" is not one of '
        '${values.map((m) => m.json).toList()}');
  }
}

/// Directory access classes; the JSON preopen spelling is `ro`/`rw`.
enum DirAccessKind {
  read('ro'),
  write('rw');

  const DirAccessKind(this.json);

  final String json;

  static DirAccessKind parse(String value) {
    for (final kind in values) {
      if (kind.json == value) return kind;
    }
    throw CapabilityDocumentException(
        'unknown preopen access "$value" (want "ro" or "rw")');
  }
}

/// How a command rule judges a command line.
enum CommandVerdict {
  allow('allow'),
  deny('deny'),
  ask('ask');

  const CommandVerdict(this.json);

  final String json;

  static CommandVerdict parse(String value) {
    for (final verdict in values) {
      if (verdict.json == value) return verdict;
    }
    throw CapabilityDocumentException('unknown verdict "$value"');
  }
}

/// The plugin grant vocabulary the host understands today; anything else
/// fails the document (fail closed).
const pluginGrantVocabulary = [
  'session.read-context',
  'engine-service-import',
  'engine-service-call',
];

/// One directory grant: canonical host path, the guest name it is
/// preopened under (structural entries: `.`, `config`, `store`; derived
/// grants: `read-<n>` / `write-<n>`; runtime widenings carry none), and
/// the entry's source.
final class DirectoryEntry {
  const DirectoryEntry({
    required this.path,
    this.guest,
    required this.origin,
  });

  final String path;
  final String? guest;
  final String origin;

  @override
  bool operator ==(Object other) =>
      other is DirectoryEntry &&
      other.path == path &&
      other.guest == guest &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(path, guest, origin);

  Map<String, Object?> toJson() => {
        'path': path,
        'guest': guest,
        'origin': origin,
      };

  static DirectoryEntry fromJson(Map<String, Object?> json) =>
      DirectoryEntry(
        path: _string(json, 'path'),
        guest: _stringOrNull(json, 'guest'),
        origin: _string(json, 'origin'),
      );
}

/// One allowed network domain: `host`, `host:port`, or `*.suffix`.
final class DomainEntry {

  const DomainEntry({required this.domain, required this.origin});

  final String domain;
  final String origin;

  @override
  bool operator ==(Object other) =>
      other is DomainEntry && other.domain == domain && other.origin == origin;

  @override
  int get hashCode => Object.hash(domain, origin);

  Map<String, Object?> toJson() => {'domain': domain, 'origin': origin};

  static DomainEntry fromJson(Map<String, Object?> json) => DomainEntry(
        domain: _string(json, 'domain'),
        origin: _string(json, 'origin'),
      );
}

/// One command rule, anchored to the whole command line; first match
/// decides, no match uses the document's default verdict.
final class CommandRule {

  const CommandRule({
    required this.pattern,
    required this.verdict,
    required this.origin,
  });

  final String pattern;
  final CommandVerdict verdict;
  final String origin;

  @override
  bool operator ==(Object other) =>
      other is CommandRule && other.pattern == pattern && other.verdict == verdict && other.origin == origin;

  @override
  int get hashCode => Object.hash(pattern, verdict, origin);

  Map<String, Object?> toJson() => {
        'pattern': pattern,
        'verdict': verdict.json,
        'origin': origin,
      };

  static CommandRule fromJson(Map<String, Object?> json) => CommandRule(
        pattern: _string(json, 'pattern'),
        verdict: CommandVerdict.parse(_string(json, 'verdict')),
        origin: _string(json, 'origin'),
      );
}

/// Grants for one plugin id.
final class PluginEntry {

  const PluginEntry({
    required this.plugin,
    required this.grants,
    required this.origin,
  });

  final String plugin;
  final List<String> grants;
  final String origin;

  @override
  bool operator ==(Object other) =>
      other is PluginEntry && other.plugin == plugin && other.origin == origin && _listEquals(other.grants, grants);

  @override
  int get hashCode => Object.hash(plugin, origin, Object.hashAll(grants));

  Map<String, Object?> toJson() => {
        'plugin': plugin,
        'grants': List<String>.of(grants),
        'origin': origin,
      };

  static PluginEntry fromJson(Map<String, Object?> json) => PluginEntry(
        plugin: _string(json, 'plugin'),
        grants: _strings(json, 'grants'),
        origin: _string(json, 'origin'),
      );
}

/// One preopen the host materializes at instantiation.
final class PreopenEntry {

  const PreopenEntry({
    required this.guest,
    required this.host,
    required this.access,
    required this.origin,
  });

  final String guest;
  final String host;
  final DirAccessKind access;
  final String origin;

  @override
  bool operator ==(Object other) =>
      other is PreopenEntry && other.guest == guest && other.host == host && other.access == access && other.origin == origin;

  @override
  int get hashCode => Object.hash(guest, host, access, origin);

  Map<String, Object?> toJson() => {
        'guest': guest,
        'host': host,
        'access': access.json,
        'origin': origin,
      };

  static PreopenEntry fromJson(Map<String, Object?> json) => PreopenEntry(
        guest: _string(json, 'guest'),
        host: _string(json, 'host'),
        access: DirAccessKind.parse(_string(json, 'access')),
        origin: _string(json, 'origin'),
      );
}

/// The validated capability document.
final class CapabilityDocument {
  CapabilityDocument({
    this.version = 1,
    required this.mode,
    required this.workspace,
    required List<DirectoryEntry> readDirectories,
    required List<DirectoryEntry> writeDirectories,
    required this.allowAllDomains,
    required List<DomainEntry> domains,
    this.defaultVerdict = CommandVerdict.ask,
    required List<CommandRule> rules,
    required List<PluginEntry> pluginGrants,
    required List<String> protectedPaths,
  })  : readDirectories = List.unmodifiable(readDirectories),
        writeDirectories = List.unmodifiable(writeDirectories),
        domains = List.unmodifiable(domains),
        rules = List.unmodifiable(rules),
        pluginGrants = List.unmodifiable(pluginGrants),
        protectedPaths = List.unmodifiable(protectedPaths),
        preopens = List.unmodifiable(_derivePreopens(
          readDirectories,
          writeDirectories,
        ));

  final int version;
  final CapabilityMode mode;
  final String workspace;
  final List<DirectoryEntry> readDirectories;
  final List<DirectoryEntry> writeDirectories;
  final bool allowAllDomains;
  final List<DomainEntry> domains;
  final CommandVerdict defaultVerdict;
  final List<CommandRule> rules;
  final List<PluginEntry> pluginGrants;
  final List<String> protectedPaths;

  /// Derived from the directory grants: writes rw, reads ro, entries
  /// without a guest name (runtime widenings) excluded. The host derives
  /// the same way and refuses a document whose `preopens` disagree.
  final List<PreopenEntry> preopens;

  /// The JSON wire form.
  Map<String, Object?> toJson() => {
        'version': version,
        'mode': mode.json,
        'workspace': workspace,
        'directories': {
          'read': [for (final d in readDirectories) d.toJson()],
          'write': [for (final d in writeDirectories) d.toJson()],
        },
        'network': {
          'allow_all': allowAllDomains,
          'domains': [for (final d in domains) d.toJson()],
        },
        'commands': {
          'default_verdict': defaultVerdict.json,
          'rules': [for (final r in rules) r.toJson()],
        },
        'plugins': {
          'grants': [for (final p in pluginGrants) p.toJson()],
        },
        'protected_paths': List<String>.of(protectedPaths),
        'preopens': [for (final p in preopens) p.toJson()],
      };

  String encode() => jsonEncode(toJson());

  /// Parses and validates. Every violation fails the whole document.
  static CapabilityDocument decode(String text) =>
      fromJson(jsonDecode(text) as Map<String, Object?>);

  static CapabilityDocument fromJson(Map<String, Object?> json) {
    _rejectUnknownKeys(json, const [
      'version',
      'mode',
      'workspace',
      'directories',
      'network',
      'commands',
      'plugins',
      'protected_paths',
      'preopens',
    ], 'capability document');
    final version = json['version'];
    if (version is! int || version != 1) {
      throw CapabilityDocumentException(
          'capability document version $version is not supported (want 1)');
    }
    final mode = CapabilityMode.parse(_string(json, 'mode'));
    final workspace = _string(json, 'workspace');
    if (!workspace.startsWith('/')) {
      throw CapabilityDocumentException(
          'capability document workspace "$workspace" is not an absolute path');
    }

    final protectedPaths = protectedPathsOf(json)
        .map((path) => _normalizedProtected(path))
        .toList();

    final directories = json['directories'];
    if (directories is! Map<String, Object?>) {
      throw CapabilityDocumentException('directories must be an object');
    }
    _rejectUnknownKeys(directories, const ['read', 'write'], 'directories');
    final readDirectories =
        _dirList(directories['read'], 'read', protectedPaths);
    final writeDirectories =
        _dirList(directories['write'], 'write', protectedPaths);

    final network = json['network'];
    if (network is! Map<String, Object?>) {
      throw CapabilityDocumentException('network must be an object');
    }
    _rejectUnknownKeys(network, const ['allow_all', 'domains'], 'network');
    final allowAll = network['allow_all'];
    if (allowAll is! bool) {
      throw CapabilityDocumentException('network.allow_all must be a bool');
    }
    final domains = _list(network['domains'], 'network.domains')
        .map((e) => _validatedDomain(e))
        .toList();

    final commands = json['commands'];
    if (commands is! Map<String, Object?>) {
      throw CapabilityDocumentException('commands must be an object');
    }
    _rejectUnknownKeys(
        commands, const ['default_verdict', 'rules'], 'commands');
    final defaultVerdict =
        CommandVerdict.parse(_string(commands, 'default_verdict'));
    final rules = _list(commands['rules'], 'commands.rules')
        .map((e) => _validatedRule(e))
        .toList();

    final plugins = json['plugins'];
    if (plugins is! Map<String, Object?>) {
      throw CapabilityDocumentException('plugins must be an object');
    }
    _rejectUnknownKeys(plugins, const ['grants'], 'plugins');
    final pluginGrants = _list(plugins['grants'], 'plugins.grants')
        .map((e) => _validatedPlugin(e))
        .toList();

    final preopens = _list(json['preopens'], 'preopens')
        .map(PreopenEntry.fromJson)
        .toList();

    final document = CapabilityDocument(
      mode: mode,
      workspace: workspace,
      readDirectories: readDirectories,
      writeDirectories: writeDirectories,
      allowAllDomains: allowAll,
      domains: domains,
      defaultVerdict: defaultVerdict,
      rules: rules,
      pluginGrants: pluginGrants,
      protectedPaths: protectedPaths,
    );

    // The declared preopens must equal the derivation from the grants.
    final declaredEqualsDerived = preopens.length == document.preopens.length &&
        [
          for (var i = 0; i < preopens.length; i++)
            _preopenMatches(preopens[i], document.preopens[i])
        ].every((same) => same);
    if (!declaredEqualsDerived) {
      throw CapabilityDocumentException(
          'capability document preopens disagree with the derivation from '
          'its directory grants');
    }
    return document;
  }
}

/// Throws on every structural violation of the document format.
class CapabilityDocumentException implements Exception {
  CapabilityDocumentException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Validation internals
// ---------------------------------------------------------------------------

List<PreopenEntry> _derivePreopens(
  List<DirectoryEntry> readDirectories,
  List<DirectoryEntry> writeDirectories,
) {
  return [
    for (final dir in writeDirectories)
      if (dir.guest != null)
        PreopenEntry(
          guest: dir.guest!,
          host: dir.path,
          access: DirAccessKind.write,
          origin: dir.origin,
        ),
    for (final dir in readDirectories)
      if (dir.guest != null)
        PreopenEntry(
          guest: dir.guest!,
          host: dir.path,
          access: DirAccessKind.read,
          origin: dir.origin,
        ),
  ];
}

bool _preopenMatches(PreopenEntry declared, PreopenEntry derived) =>
    declared.guest == derived.guest &&
    declared.host == derived.host &&
    declared.access == derived.access &&
    declared.origin == derived.origin;

/// `protected_paths` as written (pre-normalization), for the overlap
/// checks during directory validation.
List<String> protectedPathsOf(Map<String, Object?> json) {
  final value = json['protected_paths'];
  if (value == null) return const [];
  if (value is! List) {
    throw CapabilityDocumentException('protected_paths must be a list');
  }
  return [for (final entry in value) entry as String];
}

List<DirectoryEntry> _dirList(
    Object? value, String label, List<String> protectedPaths) {
  final entries = _list(value, 'directories.$label');
  final guests = <String>{};
  final result = <DirectoryEntry>[];
  for (final entry in entries) {
    final dir = DirectoryEntry.fromJson(entry);
    _validateGuestName(dir.guest);
    if (dir.guest != null && !guests.add(dir.guest!)) {
      throw CapabilityDocumentException(
          'duplicate guest directory name "${dir.guest}"');
    }
    if (!dir.path.startsWith('/')) {
      throw CapabilityDocumentException(
          '$label directory "${dir.path}" is not an absolute path');
    }
    for (final protected in protectedPaths) {
      // A grant landing on or inside a protected path is a hole - refuse
      // it. A protected leaf *beneath* a broader grant is the native
      // model (known credentials stay protected beneath broader grants,
      // enforced by masking); the preopen wall cannot be finer than the
      // preopen, so it is recorded, not refused.
      if (dir.path == protected || dir.path.startsWith('$protected/')) {
        throw CapabilityDocumentException(
            '$label directory "${dir.path}" lands inside protected path '
            '"$protected"');
      }
    }
    result.add(dir);
  }
  return result;
}



bool _listEquals(List<String> a, List<String> b) =>
    a.length == b.length && [
      for (var i = 0; i < a.length; i++) a[i] == b[i],
    ].every((same) => same);

void _validateGuestName(String? guest) {
  if (guest == null) return;
  final valid = guest.isNotEmpty &&
      guest.length <= 128 &&
      guest.codeUnits.every((unit) =>
          (unit >= 0x30 && unit <= 0x39) || // 0-9
          (unit >= 0x41 && unit <= 0x5A) || // A-Z
          (unit >= 0x61 && unit <= 0x7A) || // a-z
          unit == 0x2E || // .
          unit == 0x5F || // _
          unit == 0x2D // -
          );
  if (!valid) {
    throw CapabilityDocumentException('invalid guest directory name "$guest"');
  }
}

DomainEntry _validatedDomain(Map<String, Object?> entry) {
  _rejectUnknownKeys(entry, const ['domain', 'origin'], 'network domain');
  final domain = DomainEntry.fromJson(entry).domain.toLowerCase();
  if (domain.isEmpty || domain.length > 253) {
    throw CapabilityDocumentException('invalid network domain "$domain"');
  }
  var host = domain;
  if (domain.contains(':')) {
    final split = domain.lastIndexOf(':');
    final portPart = domain.substring(split + 1);
    final port = int.tryParse(portPart);
    if (port == null || port < 1 || port > 65535 || split == 0) {
      throw CapabilityDocumentException(
          'invalid network domain "$domain": bad port');
    }
    host = domain.substring(0, split);
  }
  final wildcard = host.startsWith('*.');
  if (wildcard) {
    final suffix = host.substring(2);
    if (suffix.isEmpty || !suffix.contains(RegExp(r'[^.]'))) {
      throw CapabilityDocumentException(
          'invalid network domain "$domain": empty wildcard suffix');
    }
  }
  final labels = host.split('.');
  if (labels.any((label) => label.isEmpty)) {
    throw CapabilityDocumentException(
        'invalid network domain "$domain": empty label');
  }
  for (final unit in host.codeUnits) {
    final ok = (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A) ||
        unit == 0x2E ||
        unit == 0x2D ||
        unit == 0x2A; // *
    if (!ok) {
      throw CapabilityDocumentException(
          'invalid network domain "$domain": bad character');
    }
  }
  return DomainEntry(domain: domain, origin: _string(entry, 'origin'));
}

CommandRule _validatedRule(Map<String, Object?> entry) {
  _rejectUnknownKeys(
      entry, const ['pattern', 'verdict', 'origin'], 'command rule');
  final rule = CommandRule.fromJson(entry);
  if (rule.pattern.isEmpty || rule.pattern.length > 2048) {
    throw CapabilityDocumentException(
        'command rule pattern of ${rule.pattern.length} bytes is outside '
        'the 1..=2048 range');
  }
  try {
    // Anchored like tina_mode's command patterns: the pattern must cover
    // the whole command line, so a `git status` rule never answers
    // `git status --porcelain`.
    RegExp('^(?:${rule.pattern})\$');
  } on FormatException catch (error) {
    throw CapabilityDocumentException(
        'command rule "${rule.pattern}" is not a valid pattern: $error');
  }
  return rule;
}

PluginEntry _validatedPlugin(Map<String, Object?> entry) {
  _rejectUnknownKeys(entry, const ['plugin', 'grants', 'origin'], 'plugin');
  final plugin = PluginEntry.fromJson(entry);
  if (plugin.plugin.isEmpty) {
    throw CapabilityDocumentException('plugin id is empty');
  }
  for (final grant in plugin.grants) {
    if (!pluginGrantVocabulary.contains(grant)) {
      throw CapabilityDocumentException(
          'unknown plugin grant "$grant" (want one of '
          '$pluginGrantVocabulary)');
    }
  }
  return plugin;
}

String _normalizedProtected(String path) {
  if (!path.startsWith('/')) {
    throw CapabilityDocumentException(
        'protected path "$path" is not an absolute path');
  }
  // Protected paths may be absent (a masked credential leaf); they are
  // normalized component-wise, `..` resolved, without requiring existence.
  final parts = <String>[];
  for (final part in path.split('/').skip(1)) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) {
        throw CapabilityDocumentException(
            'protected path "$path" climbs out of the root with `..`');
      }
      parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return '/${parts.join('/')}';
}

void _rejectUnknownKeys(
    Map<String, Object?> json, List<String> allowed, String what) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw CapabilityDocumentException(
          '$what has unknown key "$key" (fail closed)');
    }
  }
}

List<Map<String, Object?>> _list(Object? value, String label) {
  if (value is! List) {
    throw CapabilityDocumentException('$label must be a list');
  }
  return [
    for (final entry in value)
      if (entry is Map<String, Object?>)
        entry
      else
        throw CapabilityDocumentException('$label entries must be objects'),
  ];
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw CapabilityDocumentException('$key must be a string');
  }
  return value;
}

String? _stringOrNull(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw CapabilityDocumentException('$key must be a string or null');
  }
  return value;
}

List<String> _strings(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw CapabilityDocumentException('$key must be a list of strings');
  }
  return [
    for (final entry in value)
      if (entry is String) entry else throw CapabilityDocumentException('$key entries must be strings'),
  ];
}
