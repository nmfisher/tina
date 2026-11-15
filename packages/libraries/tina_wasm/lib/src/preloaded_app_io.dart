/// The wasm engine's [AppIo] (the app assembly's synchronous seam): a
/// snapshot preloaded from the preopened config tree and the workspace's
/// `.tina` directory before the synchronous assembly boots, with writes
/// held in memory (the exit-test session writes no configuration; the
/// deviation is recorded in the stage-5 notes).
///
/// The snapshot is BOUNDED, on purpose: booting in a workspace whose
/// `.tina` holds large files (a long-lived session store, an exported
/// log) must not copy them all into the guest heap as Latin1 strings —
/// an unbounded walk crashed real boots (`String.fromCharCodes` →
/// `Latin1String.fromAsciiBytes` → `cloneTyped` trap on a big file).
/// Files larger than [maxPreloadFileBytes], files that look binary (a
/// NUL byte in the first [binarySniffWindow] bytes — Latin1 conversion
/// of binary data is pure waste), and everything after the cumulative
/// [maxPreloadTotalBytes] budget runs out are listed in [skippedFiles]
/// and left on disk. Nothing is lost by that: the agent's file tools
/// and the session store read through the WASI port directly
/// (`WasiToolFileSystem`, `WasiSessionStore`), never through this
/// snapshot, and the snapshot's real consumers — the settings documents
/// — are small by nature. A skipped file still answers `exists`, so
/// discovery sees the tree; only `readTextIfExists` declines it.
///
/// [homePath] is the config preopen's root — the `~/.tina` equivalent
/// inside the sandbox, exactly where the brief's config preopen points.
library;

import 'dart:typed_data';

import 'package:toml/toml.dart' as toml;

import 'package:tina/src/app_io.dart';
import 'package:tina/src/config_document.dart' show ConfigDocument;
import 'package:tina/src/settings_catalog.dart' show mergeSettingLayers;
import 'package:tina/src/settings_surface.dart' show ConfigSettingsSurface;
import 'package:tina/src/settings_stack.dart' show GlobalDocumentSource;
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/portable_tools.dart'
    show CommandApprovalScope, ToolCommandApprovals;
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/wasi_filesystem.dart' as fs;
import 'package:tina_wasm/src/preload_budget.dart';
import 'package:tina_wasm/src/wasm_file_system_port.dart';

/// One preloaded [AppIo].
final class PreloadedAppIo implements AppIo {
  PreloadedAppIo._(this._files, this._directories, this._skipped,
      this.budgetExhausted, this._home, this._environment);

  final Map<String, String> _files;
  final Set<String> _directories;
  final Set<String> _skipped;

  /// True once the cumulative budget stopped the preload partway through
  /// the walk; [skippedFiles] from that point on were only enumerated.
  final bool budgetExhausted;

  /// Files present under the roots but intentionally not preloaded
  /// (oversized, binary, or past the budget), in walk order.
  List<String> get skippedFiles => List.unmodifiable(_skipped);

  final Map<String, String> _environment;
  final String _home;

  @override
  String? env(String name) => _environment[name];

  @override
  String get homePath => _home;

  @override
  String get currentDirectory => '.';

  @override
  bool exists(String path) =>
      _files.containsKey(_normalize(path)) ||
      _directories.contains(_normalize(path)) ||
      _skipped.contains(_normalize(path));

  @override
  bool isDirectory(String path) => _directories.contains(_normalize(path));

  @override
  String? readTextIfExists(String path) => _files[_normalize(path)];

  @override
  void createDirectory(String path, {bool recursive = false}) =>
      _directories.add(_normalize(path));

  @override
  void writeText(String path, String contents) =>
      _files[_normalize(path)] = contents;

  @override
  void deleteFile(String path) => _files.remove(_normalize(path));

  @override
  void deleteTree(String path) {
    final prefix = _normalize(path);
    _directories.remove(prefix);
    _files.removeWhere((file, _) => file == prefix || file.startsWith('$prefix/'));
  }

  @override
  void rename(String from, String to) {
    final contents = _files.remove(_normalize(from));
    if (contents != null) _files[_normalize(to)] = contents;
  }

  @override
  String createTempDirectory(String near, String prefix) {
    final dir = '$near/.tina-staging-${DateTime.now().microsecondsSinceEpoch}';
    _directories.add(_normalize(dir));
    return dir;
  }

  @override
  String absolute(String path) => path.startsWith('/') ? path : '/$path';

  @override
  String canonical(String path) => absolute(path);

  @override
  bool get canSecureFilePermissions => false;

  @override
  void secureFilePermissions(String path) =>
      throw UnsupportedError('no file permissions under WASI preopens');

  String _normalize(String path) {
    var candidate = path;
    while (candidate.startsWith('./')) {
      candidate = candidate.substring(2);
    }
    return candidate;
  }

  /// Preloads [preopens]: every bounded regular file under [roots], as
  /// UTF-8 text keyed by its guest path. See the class comment for the
  /// bounds and what skips cost (nothing: the file tools and the session
  /// store read through WASI directly).
  static Future<PreloadedAppIo> load(
    WasmPreopens preopens,
    fs.Types filesystem, {
    required List<String> roots,
    required Map<String, String> environment,
    required String home,
  }) async {
    final files = <String, String>{};
    final directories = <String>{};
    final skipped = <String>{};
    final budget = PreloadBudget();
    // Size via the parent descriptor, no open: oversized files are never
    // opened, let alone read.
    Future<int?> sizeOf(
        cm.Owned<fs.TypesDescriptor> dir, String name) async {
      final stat = await filesystem.methodDescriptorStatAt(
        self: dir.borrow(),
        pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(false),
        path: name,
      );
      return switch (stat) {
        cm.OkResult(:final value) => value.size,
        cm.ErrorResult() => null,
      };
    }

    Future<void> walk(String prefix, cm.Owned<fs.TypesDescriptor> dir,
        [int depth = 0]) async {
      if (depth > 4) return;
      directories.add(prefix);
      final (stream, done) = filesystem.methodDescriptorReadDirectory(
        self: dir.borrow(),
      );
      final names = <({String name, fs.TypesDescriptorType type})>[];
      await for (final batch in stream) {
        for (final (:name, :type) in batch) {
          names.add((name: name, type: type));
        }
      }
      switch (await done) {
        case cm.OkResult():
          break;
        case cm.ErrorResult():
          return;
      }
      for (final (:name, :type) in names) {
        final guest = prefix.isEmpty ? name : '$prefix/$name';
        if (type is fs.TypesDescriptorTypeDirectory) {
              final child = await filesystem.methodDescriptorOpenAt(
                self: dir.borrow(),
                pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(false),
                path: name,
                openFlags: fs.TypesOpenFlags(0).withDirectory(true),
                flags: fs.TypesDescriptorFlags(0),
              );
              switch (child) {
                case cm.OkResult(:final value):
                  await walk(guest, value);
                  value.drop();
                case cm.ErrorResult():
                  break;
              }
            } else if (type is fs.TypesDescriptorTypeRegularFile) {
              // Size first, via the parent descriptor: oversized files
              // are never opened, let alone read.
              final size = await sizeOf(dir, name);
              if (size == null) continue;
              if (!budget.admitStatSize(size)) {
                skipped.add(guest);
                continue;
              }
              final opened = await filesystem.methodDescriptorOpenAt(
                self: dir.borrow(),
                pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(false),
                path: name,
                openFlags: fs.TypesOpenFlags(0),
                flags: fs.TypesDescriptorFlags(0).withRead(true),
              );
              switch (opened) {
                case cm.OkResult(:final value):
                  final (reader, readDone) =
                      filesystem.methodDescriptorReadViaStream(
                    self: value.borrow(),
                    offset: 0,
                  );
                  final bytes = BytesBuilder(copy: false);
                  await for (final chunk in reader) {
                    bytes.add(chunk);
                  }
                  await readDone;
                  final data = bytes.takeBytes();
                  value.drop();
                  // The file may have grown between stat and read; the
                  // read-time size is authoritative for the caps.
                  if (!budget.admitReadBytes(data.length)) {
                    skipped.add(guest);
                    continue;
                  }
                  if (budget.looksBinary(data)) {
                    // Undo the accounting: a binary file contributes no
                    // strings to the snapshot, so it must not consume
                    // budget either.
                    budget.releaseBytes(data.length);
                    skipped.add(guest);
                    continue;
                  }
                  // Config and permissions are text; anything that is
                  // not decodes with replacement, never blocks boot.
                  files[guest] = String.fromCharCodes(data);
                case cm.ErrorResult():
                  break;
              }
            }
      }
    }

    for (final root in roots) {
      final resolved = preopens.resolve(root);
      if (resolved == null) continue;
      await walk(root == '.' ? '' : root, resolved.$1);
    }
    return PreloadedAppIo._(
        files, directories, skipped, budget.exhausted, home, environment);
  }
}

/// The preloaded settings backend: global and workspace documents from
/// the snapshot, an in-memory session layer, and the shared merge.
final class PreloadedSettingsBackend
    implements SettingsBackend, GlobalDocumentSource, ConfigSettingsSurface {
  PreloadedSettingsBackend(this._io,
      {required this.globalPath, required this.workspacePath});

  final PreloadedAppIo _io;
  final String globalPath;
  final String workspacePath;

  final Map<String, Object?> _session = {};

  String? _raw(String path) => _io.readTextIfExists(path);

  @override
  Map<String, Object?> read(SettingScope scope) => switch (scope) {
        SettingScope.session => Map.of(_session),
        SettingScope.global => _parse(globalPath),
        SettingScope.workspace => _sameFile ? {} : _parse(workspacePath),
      };

  @override
  void write(SettingScope scope, Map<String, Object?> values) {
    if (scope == SettingScope.session) {
      _session
        ..clear()
        ..addAll(values);
      return;
    }
    // The exit-test session changes no configuration; a write lands in
    // the snapshot so a later read sees it, which is the honest
    // best-effort behavior under preloads.
    _io.writeText(
        scope == SettingScope.global ? globalPath : workspacePath,
        values.entries.map((e) => '${e.key}=${e.value}').join('\n'));
  }

  bool get _sameFile => globalPath == workspacePath;

  Map<String, Object?> _parse(String path) {
    final raw = _raw(path);
    if (raw == null) return <String, Object?>{};
    try {
      return toml.TomlDocument.parse(raw).toMap();
    } catch (_) {
      return <String, Object?>{};
    }
  }

  @override
  Map<String, dynamic> globalDocument() =>
      Map<String, dynamic>.from(_parse(globalPath));

  // ---- ConfigSettingsSurface ------------------------------------------------
  //
  // The preloaded backend is session-only: nothing touches the host
  // beyond the snapshot (the stage-5 contract), so the surface members
  // answer from memory — the permission store is empty, plugin toggles
  // land in the session layer, and documents/drafts view the snapshot.

  @override
  ToolCommandApprovals get permissionStore => const _NoCommandApprovals();

  @override
  void setPluginInAllScopes(
    ScopedSettings settings,
    SettingDefinition<Object> definition,
    bool? enabled, {
    bool refresh = true,
  }) {
    final id = definition.id.endsWith('/enabled')
        ? definition.id.substring(0, definition.id.length - '/enabled'.length)
        : definition.id;
    _session['$id/enabled'] = enabled;
    if (refresh) settings.reload();
  }

  @override
  Map<String, dynamic> effectiveDocument({
    Map<SettingScope, Map<String, Object?>>? layers,
  }) =>
      mergeSettingLayers(
        globalDocument: globalDocument(),
        layers: layers ??
            {
              for (final scope in SettingScope.values) scope: read(scope),
            },
        definitions: const [],
      );

  @override
  Map<String, dynamic> document(SettingScope scope) =>
      Map<String, dynamic>.from(read(scope));

  @override
  ConfigDocument draft(
    ScopedSettings settings,
    SettingScope scope, {
    void Function(Map<String, Object?>, Set<String>)? commit,
  }) {
    final values = Map<String, dynamic>.from(read(scope));
    return ConfigDocument.draft(values, (_) {});
  }
}

/// The preloaded backend's permission store: nothing is remembered, and
/// nothing can be (approvals under wasm are session answers, not files).
final class _NoCommandApprovals implements ToolCommandApprovals {
  const _NoCommandApprovals();

  @override
  List<Map<String, Object?>> get entries => const [];

  @override
  bool coversAccess(String capability, String target) => false;

  @override
  void revoke(String id, {String? directory}) {}

  @override
  Map<String, Object?> settings(CommandApprovalScope scope) => const {};

  @override
  String? get filePath => null;
}
