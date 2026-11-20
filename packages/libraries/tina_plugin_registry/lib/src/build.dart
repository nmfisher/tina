/// Local plugin builds: compile a Dart-authored plugin source directory
/// with the local Dart SDK's wasm-component pipeline, then install the
/// artifact into the existing plugin cache with a LOCAL origin marker.
///
/// The toolchain-present path (owner decision): no in-binary compiler,
/// no registry round-trip. A locally-built artifact skips REGISTRY
/// signature verification — its trust is the user's explicit consent,
/// keyed by artifact hash ([LocalPluginConsent]; re-prompt on hash
/// change) — while the capability/policy gate is unchanged: the same
/// parsed-entry vocabulary and consent flow as registry installs.
///
/// Pure seams for tests: [PluginCompiler] is injectable and the
/// toolchain locator returns null instead of spawning anything.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'build_flow.dart';
import 'plugin_cache.dart';

/// What one compiler invocation produced.
final class PluginCompileOutcome {
  const PluginCompileOutcome({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.outputBytes,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// The artifact bytes when the compiler reports success and the
  /// output file exists; null otherwise.
  final List<int>? outputBytes;
}

/// One compilation: [source] directory in, component bytes out at
/// [output]. A missing toolchain or a failing compile throws
/// [PluginBuildException] with a clean, user-facing message.
typedef PluginCompiler = Future<PluginCompileOutcome> Function(
    Directory source, File output);

/// Locates the `dart` executable on `PATH`. Returns null when absent —
/// the caller turns that into a [PluginBuildException] naming the fix.
String? locateDart({Map<String, String>? environment}) {
  final path = (environment ?? Platform.environment)['PATH'] ?? '';
  for (final dir in path.split(Platform.pathSeparator)) {
    if (dir.isEmpty) continue;
    for (final name in const ['dart', 'dart.exe']) {
      final candidate = File(
          '$dir${Platform.pathSeparator}$name');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

/// The default compiler: the local SDK's wasm-component pipeline, the
/// same invocation the release pipeline uses for components
/// (`dart compile wasm <entry>`), run in the source directory.
PluginCompiler sdkWasmCompiler({
  String? dartExecutable,
  Map<String, String>? environment,
}) {
  return (source, output) async {
    final dart = dartExecutable ?? locateDart(environment: environment);
    if (dart == null) {
      throw const PluginBuildException(
          'no Dart SDK found on PATH — plugins build needs the dart '
          'executable to compile a wasm component; install the Dart SDK '
          '(https://dart.dev/get-dart) or add it to PATH');
    }
    final entry = _entryPoint(source);
    if (entry == null) {
      throw PluginBuildException(
          'no plugin entry point in ${source.path}: expected '
          'bin/<name>.dart (or bin/main.dart)');
    }
    final result = await Process.run(dart, [
      'compile',
      'wasm',
      entry.path,
      '-o',
      output.path,
    ], workingDirectory: source.path);
    final bytes =
        result.exitCode == 0 && output.existsSync()
            ? output.readAsBytesSync()
            : null;
    return PluginCompileOutcome(
      exitCode: result.exitCode,
      stdout: result.stdout is String ? result.stdout as String : '',
      stderr: result.stderr is String ? result.stderr as String : '',
      outputBytes: bytes,
    );
  };
}

File? _entryPoint(Directory source) {
  final bin = Directory('${source.path}${Platform.pathSeparator}bin');
  if (!bin.existsSync()) return null;
  final main = File('${bin.path}${Platform.pathSeparator}main.dart');
  if (main.existsSync()) return main;
  final names = bin.listSync().whereType<File>().toList()..sort();
  for (final file in names) {
    if (file.path.endsWith('.dart')) return file;
  }
  return null;
}

/// A successful local build moved to `build_flow.dart`: the shared,
/// `dart:io`-free record both build surfaces report.

/// Builds and installs local plugin artifacts into the [cache].
final class PluginBuildService {
  PluginBuildService({
    required this.cache,
    PluginCompiler? compiler,
    DateTime Function()? now,
  }) : _compiler = compiler,
       _now = now ?? DateTime.now;

  final PluginCache cache;
  final PluginCompiler? _compiler;
  final DateTime Function() _now;

  /// Compiles [source] and installs the artifact under [name] with
  /// `origin: local`, the artifact hash and the build timestamp in the
  /// cache's install record. Compiler failures surface their stderr
  /// through [PluginBuildException].
  Future<LocalPluginBuild> build(Directory source, String name) async {
    if (!source.existsSync()) {
      throw PluginBuildException(
          'plugin source directory not found: ${source.path}');
    }
    final compiler = _compiler;
    if (compiler == null) {
      throw const PluginBuildException(
          'no compiler configured for plugin builds in this composition');
    }
    if (_entryPoint(source) == null) {
      throw PluginBuildException(
          'no plugin entry point in ${source.path}: expected '
          'bin/<name>.dart (or bin/main.dart)');
    }
    final staging = Directory.systemTemp.createTempSync('tina-plugin-build-');
    try {
      final output = File(
          '${staging.path}${Platform.pathSeparator}component.wasm');
      final outcome = await compiler(source, output);
      final bytes = outcome.outputBytes;
      if (outcome.exitCode != 0 || bytes == null || bytes.isEmpty) {
        throw PluginBuildException(
            'plugin compilation failed (exit ${outcome.exitCode})',
            stderr: outcome.stderr);
      }
      final hash = crypto.sha256.convert(bytes).toString();
      final version = 'local-${hash.substring(0, 12)}';
      final builtAt = _now().toUtc();
      await cache.install(
        name: name,
        version: version,
        componentBytes: bytes,
        grants: const [],
        deniedIds: const [],
        origin: 'local',
        artifactHash: hash,
        builtAt: builtAt,
      );
      return LocalPluginBuild(
        name: name,
        version: version,
        hash: hash,
        componentPath: cache.componentFile(name, version).path,
        builtAt: builtAt,
      );
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// Local-trust consent, keyed by artifact hash: consent once per build,
/// re-prompt on hash change. Persisted as a small JSON list under the
/// plugin cache root, so it survives sessions. The [LocalConsentBook]
/// interface (in `build_flow.dart`) is what the shared flow codes
/// against; this file-backed book is the native implementation.
final class LocalPluginConsent implements LocalConsentBook {
  LocalPluginConsent({required this.file});

  /// `<cache root>/local-consent.json`.
  final File file;

  Set<String>? _cache;

  /// Whether this artifact hash still needs an explicit consent.
  bool needsConsent(String hash) {
    _read();
    return !_cache!.contains(hash);
  }

  /// Records the consent for [hash] (durable, best-effort write).
  void remember(String hash) {
    _read();
    if (!_cache!.add(hash)) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
          jsonEncode({'consented': _cache!.toList()..sort()}), flush: true);
    } on Object {
      // A consent book that cannot persist re-prompts next session —
      // the safe direction; never blocks the session.
    }
  }

  void _read() {
    if (_cache != null) return;
    final stored = <String>{};
    try {
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map && decoded['consented'] is List) {
          stored.addAll(
              (decoded['consented'] as List).whereType<String>());
        }
      }
    } on Object {
      // A damaged book reads as empty: re-prompt (safe direction).
    }
    _cache = stored;
  }
}
