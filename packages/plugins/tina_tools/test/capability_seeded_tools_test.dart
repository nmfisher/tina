import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_capability/tina_capability.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_mode/tina_mode.dart' show PermissionMode;

void main() {
  late Directory workspace;
  late Directory tinaDir;
  late Directory readGrant;
  late Directory writeGrant;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tina-cap-tools');
    tinaDir = Directory(p.join(workspace.path, '.tina'))..createSync();
    readGrant = Directory.systemTemp.createTempSync('tina-cap-read');
    writeGrant = Directory.systemTemp.createTempSync('tina-cap-write');
  });

  tearDown(() {
    workspace.deleteSync(recursive: true);
    readGrant.deleteSync(recursive: true);
    writeGrant.deleteSync(recursive: true);
  });

  CapabilityDocument document({
    CapabilityMode mode = CapabilityMode.allowEdits,
    List<String> read = const [],
    List<String> write = const [],
    List<String> protected = const [],
  }) {
    return compileCapabilities(CapabilityInputs(
      mode: mode,
      workspace: workspace.path,
      configDir: tinaDir.path,
      readDirectories: read,
      writeDirectories: write,
      protectedPaths: protected,
    ));
  }

  ToolsPlugin plugin(CapabilityDocument doc, {List<String>? protectedPaths}) {
    return ToolsPlugin(
      workspaceRoot: workspace.path,
      tinaDir: tinaDir,
      osSandbox: false,
      mode: PermissionMode.ask,
      protectedPaths: protectedPaths ?? const [],
      capabilities: doc,
    );
  }

  test('document grants seed the tables native enforcement consults', () {
    final doc = document(read: [readGrant.path], write: [writeGrant.path]);
    final built = plugin(doc);
    expect(
      built.readDirectories.paths,
      contains(readGrant.path),
      reason: 'the document is the source of truth for read grants',
    );
    expect(
      built.writeDirectories.paths,
      contains(writeGrant.path),
    );
    // Structural entries do not become standing user grants.
    expect(
      built.writeDirectories.paths
          .where((path) => path != writeGrant.path && path != workspace.path),
      isEmpty,
    );
    // The OS plan consumed the document's protected paths too.
    expect(built.osPlan.isProtected(p.join(workspace.path, '.tina')), isTrue,
        reason: 'the tina dir is protected by the plan');
  });

  test('document protected paths join the plan beneath broader grants', () {
    final secret = File(p.join(workspace.path, 'secrets', 'key.json'))
      ..createSync(recursive: true);
    final doc = document(protected: [secret.parent.path]);
    final built = plugin(doc);
    expect(built.osPlan.isProtected(secret.path), isTrue,
        reason: 'a protected leaf beneath the workspace grant is masked');
  });

  test('a grant landing inside a protected path cannot be compiled', () {
    final secret = Directory(p.join(workspace.path, 'secrets'))
      ..createSync(recursive: true);
    expect(
      () => document(read: [secret.path], protected: [secret.parent.path]),
      throwsA(isA<CapabilityDocumentException>()),
      reason: 'granting a protected subtree is a hole',
    );
  });

  test('read-only mode seeds no write grants and the workspace stays ro',
      () {
    final doc = document(mode: CapabilityMode.readOnly);
    final built = plugin(doc);
    expect(built.writeDirectories.paths, isEmpty);
  });
}
