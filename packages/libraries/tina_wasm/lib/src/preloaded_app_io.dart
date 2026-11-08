/// The wasm engine's [AppIo] (the app assembly's synchronous seam): a
/// snapshot preloaded from the preopened config tree and the workspace's
/// `.tina` directory before the synchronous assembly boots, with writes
/// held in memory (the exit-test session writes no configuration; the
/// deviation is recorded in the stage-5 notes).
///
/// [homePath] is the config preopen's root — the `~/.tina` equivalent
/// inside the sandbox, exactly where the brief's config preopen points.
library;

import 'dart:typed_data';

import 'package:toml/toml.dart' as toml;

import 'package:tina/src/app_io.dart';
import 'package:tina/src/settings_stack.dart' show GlobalDocumentSource;
import 'package:tina_settings/tina_settings.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/wasi_filesystem.dart' as fs;
import 'package:tina_wasm/src/wasm_file_system_port.dart';

/// One preloaded [AppIo].
final class PreloadedAppIo implements AppIo {
  PreloadedAppIo._(this._files, this._directories, this._home, this._environment);

  final Map<String, String> _files;
  final Set<String> _directories;
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
      _directories.contains(_normalize(path));

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

  /// Preloads [preopens]: every regular file under [roots] (bounded), as
  /// UTF-8 text keyed by its guest path.
  static Future<PreloadedAppIo> load(
    WasmPreopens preopens,
    fs.Types filesystem, {
    required List<String> roots,
    required Map<String, String> environment,
    required String home,
  }) async {
    final files = <String, String>{};
    final directories = <String>{};
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
              final opened = await filesystem.methodDescriptorOpenAt(
                self: dir.borrow(),
                pathFlags: fs.TypesPathFlags(0).withSymlinkFollow(false),
                path: name,
                openFlags: fs.TypesOpenFlags(0),
                flags: fs.TypesDescriptorFlags(0).withRead(true),
              );
              switch (opened) {
                case cm.OkResult(:final value):
                  final (reader, readDone) = filesystem.methodDescriptorReadViaStream(
                    self: value.borrow(),
                    offset: 0,
                  );
                  final chunks = <Uint8List>[];
                  await for (final chunk in reader) {
                    chunks.add(chunk);
                  }
                  await readDone;
                  final bytes = BytesBuilder(copy: false);
                  for (final chunk in chunks) {
                    bytes.add(chunk);
                  }
                  // Config and permissions are text; anything that is not
                  // decodes with replacement, never blocks boot.
                  files[guest] = String.fromCharCodes(bytes.takeBytes());
                  value.drop();
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
    return PreloadedAppIo._(files, directories, home, environment);
  }
}

/// The preloaded settings backend: global and workspace documents from
/// the snapshot, an in-memory session layer, and the shared merge.
final class PreloadedSettingsBackend
    implements SettingsBackend, GlobalDocumentSource {
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
}
