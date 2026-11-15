import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart';
import 'package:tina_plugin_registry/tina_plugin_registry.dart';

/// Fixtures committed next to this test: the cross_vector entry was signed
/// by the Rust publisher (tools/plugin-registry) with the key in
/// cross_vector.pub; the component is the repo's entity-decode fixture.
final testDir = Directory('test/fixtures');

Uint8List readBytes(String name) =>
    Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync());

String readText(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  test('canonical JSON sorts keys recursively without whitespace', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': {'z': true, 'y': [2, 1]},
        'c': 'x"q',
      }),
      equals('{"a":{"y":[2,1],"z":true},"b":1,"c":"x\\"q"}'),
    );
  });

  test('canonical grant strings match the publisher encoder', () {
    expect(
      canonicalGrantString({'id': 'session.read-context'}),
      'session.read-context',
    );
    expect(
      canonicalGrantString({
        'id': 'session-store',
        'access': 'redacted-read',
        'required': false,
        'summary': 'ignored',
      }),
      'session-store:access=redacted-read',
    );
    expect(
      canonicalGrantString({
        'id': 'filesystem',
        'mode': 'ro',
        'paths': ['workspace'],
        'required': false,
      }),
      'filesystem:mode=ro,paths=["workspace"]',
    );
    expect(
      canonicalGrantString({
        'id': 'network',
        'domains': ['api.example.test'],
        'required': false,
      }),
      'network:domains=["api.example.test"]',
    );
  });

  test('the committed fixture component carries the accepted stamp', () {
    final bytes = readBytes('entity_decode.component.wasm');
    expect(readEmbedderAbiStamp(bytes), embedderAbiVersion);
    requireEmbedderAbi(bytes); // does not throw
  });

  test('stamp reader rejects a missing and a wrong-version stamp', () {
    final good = readBytes('entity_decode.component.wasm');
    // Strip the trailing stamp section: rebuild the wasm without it.
    final withoutStamp = Uint8List.sublistView(good, 0, good.length - 9);
    expect(() => readEmbedderAbiStamp(withoutStamp), throwsA(isA<AbiStampError>()));
    // A wrong version in the payload.
    final wrong = Uint8List.fromList(good);
    wrong[wrong.length - 1] = 2;
    expect(
      () => requireEmbedderAbi(wrong),
      throwsA(isA<AbiStampError>().having(
          (e) => e.message, 'message', contains('engine accepts 1'))),
    );
  });

  test('cross-implementation: the Dart verifier accepts the Rust signature',
      () {
    final entry =
        json.decode(readText('cross_vector.entry.json')) as Map<String, Object?>;
    // cross_vector.pub: "ed25519-v1 <base64>\nkey id <id>"
    final pubLine =
        readText('cross_vector.pub').split('\n').first.split(' ').last;
    final publicKey = base64.decode(pubLine);
    verifyEntrySignature(entry, Uint8List.fromList(publicKey)); // no throw

    // Tampering with any payload field breaks it.
    final tampered = Map<String, Object?>.from(entry);
    tampered['name'] = 'vector/consent-demo-evil';
    expect(
      () => verifyEntrySignature(tampered, Uint8List.fromList(publicKey)),
      throwsA(isA<SignatureVerificationError>()),
    );
    // A wrong key breaks it: derive one from a different 32-byte seed.
    final otherSeed =
        Uint8List.fromList(List.generate(32, (i) => (i * 7 + 1) & 0xff));
    final otherPrivate = newKeyFromSeed(otherSeed);
    final otherPublic = public(otherPrivate);
    expect(
      () => verifyEntrySignature(entry, Uint8List.fromList(otherPublic.bytes)),
      throwsA(isA<SignatureVerificationError>()),
    );
  });

  test('entry schema validation', () {
    expect(() => parseEntry({}), throwsA(isA<EntrySchemaError>()));
    final valid = {
      'name': 'x/y',
      'version': '0.1.0',
      'artifact': {'sha256': 'a' * 64, 'size': 3},
      'capabilities': [
        {'id': 'session.read-context'},
      ],
    };
    final parsed = parseEntry(valid);
    expect(parsed.grantStrings(), ['session.read-context']);
    expect(
      () => parseEntry({
        'name': 'x',
        'version': '0.1.0',
        'artifact': {'sha256': 'a' * 64, 'size': 3},
        'capabilities': [
          {'id': 'make.coffee'},
        ],
      }),
      throwsA(isA<EntrySchemaError>()),
    );
  });

  group('consent', () {
    final manifest = [
      {'id': 'session.read-context', 'required': true, 'summary': 'session'},
      {
        'id': 'session-store',
        'access': 'redacted-read',
        'required': false,
        'summary': 'history',
      },
    ];
    final entry = ParsedEntry(
      name: 'demo',
      version: '1.0.0',
      description: '',
      sha256: 'a' * 64,
      size: 1,
      blobPath: 'blobs/x.wasm',
      capabilities: manifest,
    );

    test('interactive: approve everything grants everything', () {
      final outcome = runInteractiveConsent(entry, (_) => true);
      expect(outcome.aborted, isFalse);
      expect(outcome.grantedStrings(), [
        'session.read-context',
        'session-store:access=redacted-read',
      ]);
    });

    test('denying a required capability aborts the install', () {
      var asked = 0;
      final outcome = runInteractiveConsent(entry, (q) {
        asked += 1;
        return q.capability['id'] != 'session.read-context';
      });
      expect(asked, 2, reason: 'every capability is asked');
      expect(outcome.aborted, isTrue);
      expect(outcome.abortReason, contains('required capability denied'));
    });

    test('denying an optional capability installs and degrades', () {
      final outcome = runInteractiveConsent(entry, (q) {
        return q.capability['id'] == 'session.read-context';
      });
      expect(outcome.aborted, isFalse);
      expect(outcome.grantedStrings(), ['session.read-context']);
      expect(outcome.deniedIds(), ['session-store']);
    });

    test('non-interactive: only explicit grants pass', () {
      final outcome = runNonInteractiveConsent(entry, {'session.read-context'});
      expect(outcome.aborted, isFalse);
      expect(outcome.grantedStrings(), ['session.read-context']);
      final deniedRequired = runNonInteractiveConsent(entry, {});
      expect(deniedRequired.aborted, isTrue);
    });

    test('session-store consent copy names the surface and the default',
        () {
      final copy = consentCopy(manifest[1]);
      expect(copy, contains('redacted'));
      expect(copy, contains('NOT included'));
      expect(copy, contains('denied'));
      final full = consentCopy({
        'id': 'session-store',
        'access': 'read',
        'required': false,
        'summary': 'all of it',
      });
      expect(full, contains('FULL PAST CONVERSATION HISTORY'));
    });
  });

  group('cache + config', () {
    late Directory scratch;
    setUp(() {
      scratch = Directory.systemTemp.createTempSync('tina-plugin-registry-test');
    });
    tearDown(() {
      scratch.deleteSync(recursive: true);
    });

    test('install/remove/list round trip', () async {
      final cache = PluginCache(root: Directory('${scratch.path}/plugins'));
      await cache.install(
        name: 'tina/wasm-prompt',
        version: '0.1.0',
        componentBytes: [1, 2, 3],
        entry: {'name': 'tina/wasm-prompt', 'version': '0.1.0'},
        grants: ['session.read-context'],
        deniedIds: ['session-store:access=redacted-read'],
      );
      final records = await cache.list();
      expect(records, hasLength(1));
      expect(records.single.name, 'tina/wasm-prompt');
      expect(records.single.grants, ['session.read-context']);
      expect(
        File(records.single.componentPath).readAsBytesSync(),
        [1, 2, 3],
      );
      await cache.remove('tina/wasm-prompt');
      expect(await cache.list(), isEmpty);
    });

    test('config section round trip preserves other content', () {
      final config = File('${scratch.path}/config');
      config.writeAsStringSync('version = 1\n\n[default]\nmodel = "x"\n');
      final registry = RegistryConfig(config);
      final data = registry.read();
      data.url = 'http://127.0.0.1:8642';
      data.key = 'KEY';
      data.active = 'tina/wasm-prompt';
      data.installed = ['tina/wasm-prompt@0.1.0'];
      registry.write(data);
      registry.write(data); // idempotent rewrite

      final text = config.readAsStringSync();
      expect(text, contains('[default]'));
      expect(text, contains('model = "x"'));
      expect(text, contains('[plugin-registry]'));
      expect(RegExp(r'\[plugin-registry\]').allMatches(text), hasLength(1));
      final read = registry.read();
      expect(read.url, 'http://127.0.0.1:8642');
      expect(read.key, 'KEY');
      expect(read.active, 'tina/wasm-prompt');
      expect(read.installed, ['tina/wasm-prompt@0.1.0']);
    });
  });

  group('install orchestration', () {
    late Directory scratch;
    setUp(() {
      scratch = Directory.systemTemp.createTempSync('tina-plugin-registry-install');
    });
    tearDown(() {
      scratch.deleteSync(recursive: true);
    });

    test('verified install: consent -> cache -> config, unenforced flagged',
        () async {
      final entryBytes = readBytes('cross_vector.entry.json');
      final entry =
          json.decode(utf8.decode(entryBytes)) as Map<String, Object?>;
      final component = readBytes('entity_decode.component.wasm');
      final pubLine = readText('cross_vector.pub').split('\n').first.split(' ').last;
      final key = Uint8List.fromList(base64.decode(pubLine));

      final cache = PluginCache(root: Directory('${scratch.path}/plugins'));
      final config = RegistryConfig(File('${scratch.path}/config'));
      ConsentOutcome flow(ParsedEntry parsed) =>
          runNonInteractiveConsent(parsed, {'session.read-context', 'filesystem'});

      final outcome = await installVerified(
        entry: entry,
        artifactBytes: component,
        pinnedPublicKey: key,
        cache: cache,
        config: config,
        consent: flow,
        activate: true,
      );
      expect(outcome.aborted, isFalse);
      expect(outcome.grants, contains('session.read-context'));
      expect(outcome.denied, contains('session-store:access=redacted-read'));
      // Recorded but not enforced by the running host:
      expect(outcome.unenforced, contains('filesystem:mode=ro,paths=["workspace"]'));
      expect(outcome.denied,
          contains('network:domains=["api.example.test"]'));

      final data = config.read();
      expect(data.active, 'vector/consent-demo');
      expect(data.installed, ['vector/consent-demo@1.2.3']);

      // sha256 mismatch is caught before consent or cache writes.
      expect(
        () => verifyArtifact(
          entry: entry,
          artifactBytes: Uint8List.fromList([1, 2, 3]),
          pinnedPublicKey: key,
        ),
        throwsA(isA<VerificationError>()),
      );
    });
  });
}
