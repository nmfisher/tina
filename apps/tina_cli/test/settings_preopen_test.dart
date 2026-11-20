/// The settings open path's wasm-awareness (commit 27): the working
/// directory and the permissions file resolve through the injected
/// [AppIo] seam — the preopen-shaped view the wasm composition root
/// supplies — never through `dart:io`'s absolute-path assumptions.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina/session.dart';
import 'package:tina/src/app_io.dart';
import 'package:tina/src/config_settings_management.dart';
import 'package:tina/src/permission_instructions.dart';

/// In-memory [AppIo]: the preopen-shaped filesystem the wasm
/// composition root injects — paths answer from the map, nothing
/// touches the real one.
final class _PreopenAppIo implements AppIo {
  _PreopenAppIo({String cwd = '/'}) : _cwd = cwd;

  final files = <String, String>{};
  final String _cwd;

  @override
  String get currentDirectory => _cwd;

  @override
  String? env(String name) => null;

  @override
  String get homePath => '/config-root';

  @override
  bool exists(String path) => files.containsKey(path);

  @override
  bool isDirectory(String path) => false;

  @override
  String? readTextIfExists(String path) => files[path];

  @override
  void createDirectory(String path, {bool recursive = false}) {}

  @override
  void writeText(String path, String contents) => files[path] = contents;

  @override
  void deleteFile(String path) => files.remove(path);

  @override
  void deleteTree(String path) {}

  @override
  void rename(String from, String to) => files[to] = files.remove(from)!;

  @override
  T lockExclusive<T>(String path, T Function() body) => body();

  @override
  String createTempDirectory(String near, String prefix) =>
      throw UnsupportedError('no temp directories in this fake');

  @override
  String absolute(String path) => path;

  @override
  String canonical(String path) => path;

  @override
  bool get canSecureFilePermissions => false;

  @override
  void secureFilePermissions(String path) {}
}

void main() {
  late Directory root;
  late SessionAssembly app;

  setUp(() {
    root = Directory(Directory.systemTemp
        .createTempSync('tina-settings-preopen-')
        .resolveSymbolicLinksSync());
    final workspace = Directory('${root.path}/workspace')..createSync();
    final config = File('${root.path}/config')
      ..writeAsStringSync('[default]\nmodel = "fixture"\n');
    app = SessionAssembly.start(
      providerFactory: (_) => ScriptedProvider([]),
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: workspace.path,
      ),
    );
  });

  tearDown(() {
    app.close();
    root.deleteSync(recursive: true);
  });

  ConfigSettingsManagement managementFor(_PreopenAppIo io, {String? workspace}) {
    final management = ConfigSettingsManagement(
      scopedSettings: app.settings,
      backend: app.settingsBackend,
      appIo: io,
      workspace: workspace,
    );
    addTearDown(management.close);
    return management;
  }

  test('the working directory defaults to the AppIo root, not dart:io',
      () {
    final io = _PreopenAppIo(cwd: '/preopen-ws');
    // A DIFFERENT permissions file on the real filesystem: if the path
    // resolution ever falls back to `dart:io`, this value leaks in.
    Directory('${root.path}/workspace/.tina')
      ..createSync(recursive: true);
    File('${root.path}/workspace/.tina/permissions.json').writeAsStringSync(
        jsonEncode({'version': 1, 'instructions': 'from the real fs'}));
    io.files['/preopen-ws/.tina/permissions.json'] = jsonEncode(
        {'version': 1, 'instructions': 'from the preopen root'});

    final management = managementFor(io); // workspace deliberately omitted

    expect(management.permissionInstructions, 'from the preopen root',
        reason: 'the config path resolves through the preopen root');
  });

  test('permission instructions read and write through the seam', () {
    final io = _PreopenAppIo(cwd: '/preopen-ws');
    final management = managementFor(io, workspace: '/preopen-ws');

    expect(management.permissionInstructions, isNull,
        reason: 'absent in the preopen view: null, no real-fs fallback');

    management.savePermissionInstructions('  be kind, rewind  ');
    final path = '/preopen-ws/.tina/permissions.json';
    expect(io.files.containsKey(path), isTrue,
        reason: 'the save landed in the preopen view');
    final saved = jsonDecode(io.files[path]!) as Map;
    expect(saved['version'], 1);
    expect(saved['instructions'], 'be kind, rewind',
        reason: 'trimmed on save, exactly as the native path does');
    expect(management.permissionInstructions, 'be kind, rewind');

    management.savePermissionInstructions('');
    expect((jsonDecode(io.files[path]!) as Map).containsKey('instructions'),
        isFalse,
        reason: 'an empty save clears the instructions field');
  });

  test('a damaged permissions file is never replaced (PathGrants rule)',
      () {
    final io = _PreopenAppIo(cwd: '/preopen-ws');
    io.files['/preopen-ws/.tina/permissions.json'] = 'not json at all';
    final management = managementFor(io, workspace: '/preopen-ws');

    expect(() => management.savePermissionInstructions('x'),
        throwsFormatException,
        reason: 'the damaged-file guard fires through the seam too');
    expect(io.files['/preopen-ws/.tina/permissions.json'], 'not json at all');
  });

  test('readProjectPermissionInstructions is tolerant of every shape', () {
    final io = _PreopenAppIo();
    void put(String text) =>
        io.files['/ws/.tina/permissions.json'] = text;

    expect(readProjectPermissionInstructions('/ws', io: io), isNull,
        reason: 'absent file');
    put(jsonEncode({'version': 1, 'instructions': '   '}));
    expect(readProjectPermissionInstructions('/ws', io: io), isNull,
        reason: 'whitespace-only instructions read as absent');
    put(jsonEncode({'version': 1, 'instructions': 42}));
    expect(readProjectPermissionInstructions('/ws', io: io), isNull,
        reason: 'a non-string field reads as absent');
    put('garbage');
    expect(readProjectPermissionInstructions('/ws', io: io), isNull,
        reason: 'a damaged file is PathGrants\' error, never ours');
    put(jsonEncode({'version': 1, 'instructions': 'real words'}));
    expect(readProjectPermissionInstructions('/ws', io: io), 'real words');
  });
}
