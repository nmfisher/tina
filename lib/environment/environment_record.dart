import 'dart:io';

/// The single environment record: `ENVIRONMENT.md` at the repo root, versioned
/// in the main repo next to `AGENTS.md` (docs/proposals/environment_agent.md).
///
/// Two kinds of content live in one file: **intent** (Setup, Build, Test,
/// Toolchain, Auth — usually human-written) and **observed state** (the test
/// baseline and "verified at" stamps — agent-maintained). The user may edit
/// anything; the environment agent treats intent as authoritative and rewrites
/// only the observed sections from fresh measurements.
///
/// This class is the read side: a tolerant section parser plus the size-capped
/// warm-load block. The file itself is written by the environment agent through
/// the ordinary sandboxed `write`/`edit` tools — there is deliberately no
/// machine writer here, and no machine-owned state in the file (the tracking
/// entry lives under `.tina/environment/`, see [EnvironmentTrackingStore]).
///
/// Secrets never appear in the record: auth entries are references (a key
/// path, a command to check), never tokens or key material.
class EnvironmentRecord {
  EnvironmentRecord._(this._sections);

  /// The record file name, at the repo root.
  static const String fileName = 'ENVIRONMENT.md';

  /// Section headings the warm-load block reads. Anything else in the file is
  /// preserved by the parser but not injected.
  static const String toolchainSection = 'Toolchain';
  static const String setupSection = 'Setup';
  static const String buildSection = 'Build';
  static const String testSection = 'Test';
  static const String authSection = 'Auth';
  static const String baselineSection = 'Test baseline';

  /// Headings recognized by the parser (case-insensitive match on these).
  static const _knownSections = <String>{
    toolchainSection,
    setupSection,
    buildSection,
    testSection,
    authSection,
    baselineSection,
    'Observed',
  };

  final Map<String, List<String>> _sections;

  /// The record file for [projectRoot].
  static File fileFor(String projectRoot) =>
      File('$projectRoot/${EnvironmentRecord.fileName}');

  /// Whether a record exists at [projectRoot] — the first-load signal: no
  /// record means the environment agent should populate one from measurements.
  static bool exists(String projectRoot) =>
      fileFor(projectRoot).existsSync();

  /// Load and parse the record, or null when it is absent or unreadable (a
  /// corrupt record must not block startup — the warm-load block is simply
  /// omitted and the region reads stale).
  static EnvironmentRecord? load(String projectRoot) {
    final file = fileFor(projectRoot);
    if (!file.existsSync()) return null;
    try {
      return parse(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  /// Parse the record's markdown: `## Name` headings, each followed by bullet
  /// lines. Unknown headings and non-bullet prose are skipped rather than
  /// rejected — the file is user-editable, so the parser stays tolerant.
  static EnvironmentRecord parse(String markdown) {
    final sections = <String, List<String>>{};
    String? current;
    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      final heading = RegExp(r'^##\s+(.+)$').firstMatch(line);
      if (heading != null) {
        final name = heading.group(1)!.trim();
        current = _knownSections.lookup(name) ?? name;
        sections.putIfAbsent(current, () => []);
        continue;
      }
      if (current == null) continue; // preamble before the first heading.
      final bullet = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
      if (bullet != null) {
        final text = bullet.group(1)!.trim();
        if (text.isNotEmpty) sections[current]!.add(text);
      }
    }
    return EnvironmentRecord._(sections);
  }

  /// The bullets of one section, empty when the section is absent.
  List<String> bullets(String section) =>
      List.unmodifiable(_sections[section] ?? const <String>[]);

  String _joined(String section) => bullets(section).join(' ; ');

  /// The warm-load block: the record's claims as compact `key: value` lines,
  /// plus the `status:` verdict rendered by the caller from the machine-owned
  /// tracking entry — never from this file's prose. Capped at [maxBytes];
  /// truncated rather than ballooning every request (the AGENTS.md cap
  /// convention).
  String promptBlock({
    required bool stale,
    String? staleReason,
    int maxBytes = 2048,
  }) {
    final lines = <String>[
      if (_joined(toolchainSection).isNotEmpty)
        'toolchain: ${_joined(toolchainSection)}',
      if (_joined(setupSection).isNotEmpty) 'setup: ${_joined(setupSection)}',
      if (_joined(buildSection).isNotEmpty) 'build: ${_joined(buildSection)}',
      if (_joined(testSection).isNotEmpty) 'test: ${_joined(testSection)}',
      if (_joined(baselineSection).isNotEmpty)
        'baseline: ${_joined(baselineSection)} (record claims)',
      if (_joined(authSection).isNotEmpty) 'auth: ${_joined(authSection)}',
      stale
          ? 'status: STALE${staleReason == null ? '' : ' — $staleReason'}'
          : 'status: current',
    ];
    // No claims at all → no block (the status line alone says nothing worth
    // spending prompt bytes on).
    if (_sections.values.every((b) => b.isEmpty)) return '';
    var block = '<project-environment>\n${lines.join('\n')}\n</project-environment>';
    if (block.length > maxBytes) {
      block =
          '${block.substring(0, maxBytes)}\n… (truncated)\n</project-environment>';
    }
    return block;
  }
}
