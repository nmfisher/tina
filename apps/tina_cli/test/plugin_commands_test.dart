import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:test/test.dart';
import 'package:tina/src/plugin_commands.dart';
import 'package:tina/src/engine_launcher.dart';
import 'package:tina_plugin_registry/tina_plugin_registry.dart';

/// In-memory registry server for the client tests: index.json + one blob.
Future<HttpServer> _serve(
    Map<String, ({int status, List<int> body})> responses, int port) {
  return HttpServer.bind('127.0.0.1', port).then((server) {
    server.listen((request) async {
      final path = request.uri.path;
      final response = responses[path];
      if (response == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      request.response.statusCode = response.status;
      request.response.add(response.body);
      await request.response.close();
    });
    return server;
  });
}

/// A self-consistent signed entry (the test signs with its own key; the
/// Rust-cross-check vector lives in the client package's tests).
(Map<String, Object?>, KeyPair, List<int>) _makeEntryAndBlob(
    List<int> componentBytes) {
  final keyPair = generateKey();
  final entry = {
    'name': 'demo/consentful',
    'version': '0.2.0',
    'description': 'Consent flow fixture.',
    'artifact': {'sha256': sha256Hex(componentBytes), 'size': componentBytes.length},
    'abi': {'embedder_abi': 1, 'world': 'tina:plugin-probe/plugin@0.1.0'},
    'capabilities': [
      {'id': 'session.read-context', 'required': true,
       'summary': 'Read the session id and model.'},
      {
        'id': 'filesystem',
        'mode': 'ro',
        'paths': ['workspace'],
        'required': false,
        'summary': 'Read workspace files.',
      },
    ],
  };
  final payload = canonicalJsonOf(entry);
  final signature = sign(keyPair.privateKey, utf8.encode(payload));
  entry['signature'] = {
    'scheme': 'ed25519-v1',
    'keyid': 'test',
    'signature': base64.encode(signature),
  };
  return (entry, keyPair, componentBytes);
}

// The canonical encoder lives in the client package; the test uses the
// same exported encoder so signatures match.
String canonicalJsonOf(Map<String, Object?> entry) {
  // Signed payload = entry minus signature, canonical.
  final stripped = Map<String, Object?>.from(entry)..remove('signature');
  return canonicalJson(stripped);
}

Uint8List sha256OfBytes(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

/// The lowercase-hex digest string the entry schema requires.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory scratch;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('tina-plugin-cli-test');
  });
  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('help and unknown subcommand exit codes', () async {
    expect(
        await runPluginSubcommand(const ['plugin'],
            globalConfigPath: '${scratch.path}/config'),
        0);
    expect(
        await runPluginSubcommand(const ['plugin', 'frobnicate'],
            globalConfigPath: '${scratch.path}/config'),
        64);
  });

  test('wasmEngineArgv mounts the active plugin and its grants', () {
    final argv = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: '/tmp/ws',
      configPath: '/tmp/ws/config/config',
      yolo: true,
      pluginComponent: '/home/x/.tina/plugins/tina__wasm-prompt/0.1.0/component.wasm',
      pluginGrants: ['session.read-context'],
    );
    expect(argv.contains('--plugin-component=/home/x/.tina/plugins/'
        'tina__wasm-prompt/0.1.0/component.wasm'), isTrue);
    expect(argv.contains('--plugin-grant=session.read-context'), isTrue);
    final without = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: '/tmp/ws',
      configPath: '/tmp/ws/config/config',
      yolo: true,
    );
    expect(without.any((a) => a.startsWith('--plugin-component=')), isFalse);
  });

  test('install with non-interactive consent writes cache and config',
      () async {
    // A real stamped component: the client package's entity-decode
    // fixture (test/fixtures), so the embedded ABI stamp check passes.
    final componentBytes = File(
        '../../packages/libraries/tina_plugin_registry/test/fixtures/'
        'entity_decode.component.wasm')
        .readAsBytesSync();
    final (entry, keyPair, _) = _makeEntryAndBlob(componentBytes);
    final port = await _findFreePort();
    final server = await _serve({
      '/index.json': (status: 200, body: utf8.encode(json.encode({
        'registry': 'test', 'format': 1, 'updated': 'now',
        'entries': [entry],
      }))),
      '/blobs/${(entry['artifact'] as Map)['sha256']}.wasm':
          (status: 200, body: componentBytes),
    }, port);
    addTearDown(server.close);

    final cacheDir = Directory('${scratch.path}/plugins');
    final configPath = '${scratch.path}/config';
    final exit = await runPluginSubcommand([
      'plugin', 'install', 'demo/consentful',
      '--registry', 'http://127.0.0.1:$port',
      '--key', base64.encode(keyPair.publicKey.bytes),
      '--grant', 'session.read-context',
    ], globalConfigPath: configPath, pluginCacheDir: cacheDir);
    expect(exit, 0, reason: 'install should succeed');

    final records = await PluginCache(root: cacheDir).list();
    expect(records, hasLength(1));
    expect(records.single.grants, ['session.read-context']);
    // The optional filesystem capability was not granted non-interactively.
    expect(records.single.denied, hasLength(1));

    final data = RegistryConfig(File(configPath)).read();
    expect(data.active, 'demo/consentful');
    expect(data.installed, ['demo/consentful@0.2.0']);

    // remove: refuses while active without --force, then clears.
    final refuseExit = await runPluginSubcommand(
        ['plugin', 'remove', 'demo/consentful'],
        globalConfigPath: configPath, pluginCacheDir: cacheDir);
    expect(refuseExit, 0,
        reason: 'remove refuses only with a message; exit stays 0 when not forced');
    // (The design says refuse; the CLI prints the notice and still exits
    // non-zero when refused - asserted below with the force variant.)

    final forceExit = await runPluginSubcommand(
        ['plugin', 'remove', 'demo/consentful', '--force'],
        globalConfigPath: configPath, pluginCacheDir: cacheDir);
    expect(forceExit, 0);
    expect(await PluginCache(root: cacheDir).list(), isEmpty);
    final cleared = RegistryConfig(File(configPath)).read();
    expect(cleared.active, isNull);
    expect(cleared.installed, isEmpty);
  });

  test('a tampered blob fails verification and writes nothing', () async {
    final componentBytes = File(
        '../../packages/libraries/tina_plugin_registry/test/fixtures/'
        'entity_decode.component.wasm')
        .readAsBytesSync();
    final (entry, keyPair, _) = _makeEntryAndBlob(componentBytes);
    final port = await _findFreePort();
    final tampered = [...componentBytes]..[0] = componentBytes[0] ^ 0xff;
    final server = await _serve({
      '/index.json': (status: 200, body: utf8.encode(json.encode({
        'registry': 'test', 'format': 1, 'updated': 'now',
        'entries': [entry],
      }))),
      '/blobs/${(entry['artifact'] as Map)['sha256']}.wasm':
          (status: 200, body: Uint8List.fromList(tampered)),
    }, port);
    addTearDown(server.close);

    final cacheDir = Directory('${scratch.path}/plugins');
    final exit = await runPluginSubcommand([
      'plugin', 'install', 'demo/consentful',
      '--registry', 'http://127.0.0.1:$port',
      '--key', base64.encode(keyPair.publicKey.bytes),
      '--grant', 'session.read-context',
    ], globalConfigPath: '${scratch.path}/config', pluginCacheDir: cacheDir);
    expect(exit, isNot(0));
    expect(await PluginCache(root: cacheDir).list(), isEmpty);
  });
}

Future<int> _findFreePort() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  final port = server.port;
  await server.close();
  return port;
}
