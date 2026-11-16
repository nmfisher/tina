// The `tina registry` CLI surface end to end: a loopback site, the real
// subcommand routing, and the real install cache/config — the same
// machinery `tina registry add` drives in a terminal.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:test/test.dart';
import 'package:tina/tina.dart' show runRegistrySubcommand;

void main() {
  late HttpServer server;
  late Directory temp;
  late Uint8List component;
  late ed.PrivateKey secret;
  late String pubBody;
  late Map<String, Object?> entry;

  setUpAll(() {
    component = Uint8List.fromList(File(
            '../../packages/libraries/tina_plugin_registry/test/fixtures/entity_decode.component.wasm')
        .readAsBytesSync());
  });

  setUp(() async {
    final pair = ed.generateKey();
    secret = pair.privateKey;
    pubBody = base64.encode(Uint8List.fromList([
      0x45, 0x64,
      ...List.filled(8, 0x11),
      ...(pair.publicKey.bytes as List<int>),
    ]));
    entry = {
      'name': 'tina/layout-solver',
      'version': '0.1.0',
      'description': 'solver',
      'abi': {
        'embedder_abi': 1,
        'world': 'tina:layout-app/layout-plugin@1.0.0',
      },
      'capabilities': <Map<String, Object?>>[],
      'artifact': {
        'sha256': crypto.sha256.convert(component).toString(),
        'size': component.length,
        'path': 'plugins/tina-layout-solver-0.1.0.component.wasm',
      },
    };
    temp = await Directory.systemTemp.createTemp('registry_cli_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final indexBytes = utf8.encode(json.encode({
      'registry_format': 1,
      'updated': 'now',
      'entries': [entry],
    }));
    final signature = ed.sign(secret, indexBytes);
    final sigFile = 'untrusted comment: test\n'
        '${base64.encode(Uint8List.fromList([0x45, 0x64, ...List.filled(8, 0x11), ...signature]))}\n';
    server.listen((request) async {
      final response = request.response;
      final List<int> body;
      if (request.uri.path == '/registry.json') {
        body = indexBytes;
      } else if (request.uri.path == '/registry.json.minisig') {
        body = utf8.encode(sigFile);
      } else if (request.uri.path.startsWith('/plugins/')) {
        body = component;
      } else {
        response.statusCode = 404;
        await response.close();
        return;
      }
      response.headers.contentLength = body.length;
      response.add(body);
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test('add -> list -> remove through the CLI subcommand', () async {
    final configPath = '${temp.path}/config';
    final cacheDir = Directory('${temp.path}/plugins');

    final add = await runRegistrySubcommand(
      [
        'registry', 'add', 'tina/layout-solver',
        '--index-url', 'http://127.0.0.1:${server.port}',
        '--minisign-key', pubBody,
      ],
      globalConfigPath: configPath,
      pluginCacheDir: cacheDir,
    );
    expect(add, 0, reason: 'install succeeds against the loopback site');

    final configText = await File(configPath).readAsString();
    expect(configText, contains('[plugin-registry]'));
    expect(configText, contains('installed = ["tina/layout-solver@0.1.0"]'));
    expect(configText, contains('active = "tina/layout-solver"'));
    final installed = File(
            '${cacheDir.path}/tina__layout-solver/0.1.0/component.wasm')
        .readAsBytesSync();
    expect(installed, component);

    final list = await runRegistrySubcommand(
      ['registry', 'list', '--index-url', 'http://127.0.0.1:${server.port}',
       '--minisign-key', pubBody],
      globalConfigPath: configPath,
      pluginCacheDir: cacheDir,
    );
    expect(list, 0);

    final remove = await runRegistrySubcommand(
      ['registry', 'remove', 'tina/layout-solver', '--force'],
      globalConfigPath: configPath,
      pluginCacheDir: cacheDir,
    );
    expect(remove, 0);
    expect(File(configPath).readAsStringSync(),
        isNot(contains('tina/layout-solver')));
    expect(cacheDir.listSync(), isEmpty);
  });

  test('a tampered index signature fails the add with exit 1', () async {
    // Pin a WRONG key: the index signature will not match it.
    final wrong = ed.generateKey();
    final wrongPubBody = base64.encode(Uint8List.fromList([
      0x45, 0x64,
      ...List.filled(8, 0x99),
      ...(wrong.publicKey.bytes as List<int>),
    ]));
    final exit = await runRegistrySubcommand(
      [
        'registry', 'add', 'tina/layout-solver',
        '--index-url', 'http://127.0.0.1:${server.port}',
        '--minisign-key', wrongPubBody,
      ],
      globalConfigPath: '${temp.path}/config2',
      pluginCacheDir: Directory('${temp.path}/plugins2'),
    );
    expect(exit, 1);
    expect(Directory('${temp.path}/plugins2').existsSync(), isFalse);
  });

  test('an unknown plugin name is a clear error, not a stack trace',
      () async {
    final exit = await runRegistrySubcommand(
      [
        'registry', 'add', 'tina/nope',
        '--index-url', 'http://127.0.0.1:${server.port}',
        '--minisign-key', pubBody,
      ],
      globalConfigPath: '${temp.path}/config3',
      pluginCacheDir: Directory('${temp.path}/plugins3'),
    );
    expect(exit, 1);
  });

  test('non-registry invocations fall through (null)', () async {
    final exit = await runRegistrySubcommand(
      ['--version'],
      globalConfigPath: '${temp.path}/config4',
      pluginCacheDir: Directory('${temp.path}/plugins4'),
    );
    expect(exit, isNull);
  });
}
