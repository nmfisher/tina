import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_capability/tina_capability.dart';

CapabilityInputs inputs(
  CapabilityMode mode, {
  List<String> read = const [],
  List<String> write = const [],
  List<CommandRuleInput> rules = const [],
  List<DomainEntry> domains = const [],
  String? storePath,
}) {
  return CapabilityInputs(
    mode: mode,
    workspace: '/ws',
    configDir: '/home/u/.tina',
    storePath: storePath,
    readDirectories: read,
    writeDirectories: write,
    rules: rules,
    domains: domains,
    protectedPaths: const ['/home/u/.tina/credentials.json'],
  );
}

void main() {
  group('compiler: mode shaping', () {
    test('ask mode: workspace rw, ask-default commands, protected kept', () {
      final document = compileCapabilities(inputs(CapabilityMode.ask));
      expect(document.mode, CapabilityMode.ask);
      expect(document.allowAllDomains, isFalse);
      // Workspace first (guest "."), then the config tree (guest
      // "config", the engine persists settings through it).
      expect(document.writeDirectories.map((d) => d.guest), ['.', 'config']);
      expect(
        document.writeDirectories.first.origin,
        EntryOrigins.workspace,
      );
      expect(document.writeDirectories.last.origin, EntryOrigins.config);
      expect(document.defaultVerdict, CommandVerdict.ask);
      expect(document.rules, isEmpty);
      expect(document.protectedPaths, ['/home/u/.tina/credentials.json']);
      // Preopens: workspace rw (config joins in real layouts).
      expect(document.preopens.first.access, DirAccessKind.write);
      expect(document.preopens.first.guest, '.');
    });

    test('read-only mode: workspace preopens ro', () {
      final document = compileCapabilities(inputs(CapabilityMode.readOnly));
      expect(document.writeDirectories.where((d) => d.guest == '.'), isEmpty);
      expect(document.readDirectories.single.guest, '.');
      final workspace = document.preopens.singleWhere((p) => p.guest == '.');
      expect(workspace.access, DirAccessKind.read);
    });

    test('yolo mode: wildcard allow rule and allow_all domains', () {
      final document = compileCapabilities(inputs(CapabilityMode.yolo));
      expect(document.allowAllDomains, isTrue);
      expect(document.rules.single.pattern, '.*');
      expect(document.rules.single.verdict, CommandVerdict.allow);
      expect(document.rules.single.origin, EntryOrigins.yoloWildcard);
    });

    test('structural entries: config always rw, store only when outside',
        () {
      final document = compileCapabilities(
        inputs(CapabilityMode.allowEdits, storePath: '/home/u/sessions.jsonl'),
      );
      final guests = {
        for (final d in document.writeDirectories) d.guest: d,
      };
      expect(guests['config']!.origin, EntryOrigins.config);
      expect(guests['store']!.origin, EntryOrigins.store);
      // Derived grant guest names follow the structural ones.
      final indexed = compileCapabilities(
        inputs(
          CapabilityMode.allowEdits,
          storePath: '/elsewhere/store.jsonl',
          read: ['/opt/sdk'],
          write: ['/projects/related'],
        ),
      );
      final readGuests = indexed.readDirectories.map((d) => d.guest);
      final writeGuests = indexed.writeDirectories
          .map((d) => d.guest)
          .where((g) => g != '.' && g != 'config' && g != 'store');
      expect(readGuests, ['read-0']);
      expect(writeGuests, ['write-1']);
    });
  });

  group('compiler: legacy-config goldens', () {
    test('a legacy-only setup compiles to today\'s effective grants', () {
      // What yesterday's launcher passed as flags plus the settings the
      // engine read from approvals files, expressed as compiler inputs:
      // workspace + config preopens, read-only dirs, an exact git status
      // grant, the provider endpoint.
      final document = compileCapabilities(
        inputs(
          CapabilityMode.ask,
          read: ['/opt/custom-sdk'],
          rules: [
            CommandRuleInput(
              pattern: 'git status',
              verdict: CommandVerdict.allow,
              origin: EntryOrigins.grant('git-status-1'),
            ),
          ],
          domains: [
            const DomainEntry(
              domain: 'api.anthropic.com',
              origin: 'provider:anthropic',
            ),
          ],
        ),
      );
      final json = document.toJson();

      // Structural: workspace and config as preopens, byte-identical
      // guest names to yesterday's --preopen flags.
      expect(json['preopens'], [
        {
          'guest': '.',
          'host': '/ws',
          'access': 'rw',
          'origin': 'structural:workspace',
        },
        {
          'guest': 'config',
          'host': '/home/u/.tina',
          'access': 'rw',
          'origin': 'structural:config',
        },
        {
          'guest': 'read-0',
          'host': '/opt/custom-sdk',
          'access': 'ro',
          'origin': 'setting:tina/tools/read_only_directories',
        },
      ]);
      // The grant keeps its anchored pattern, verdict, and traceable id.
      expect((json['commands'] as Map)['rules'], [
        {
          'pattern': 'git status',
          'verdict': 'allow',
          'origin': 'grant:git-status-1',
        }
      ]);
      // The provider endpoint is the only allowed domain; everything else
      // routes through the approval flow, exactly as natively.
      expect((json['network'] as Map)['allow_all'], false);
      expect((json['network'] as Map)['domains'], [
        {'domain': 'api.anthropic.com', 'origin': 'provider:anthropic'}
      ]);
    });
  });

  group('codec', () {
    test('round-trips', () {
      final document = compileCapabilities(
        inputs(
          CapabilityMode.auto,
          storePath: '/elsewhere/store.jsonl',
          read: ['/opt/sdk'],
          write: ['/projects/related'],
          rules: [
            const CommandRuleInput(
              pattern: 'cargo .*',
              verdict: CommandVerdict.allow,
              origin: 'grant:cargo-1',
            ),
          ],
          domains: const [
            DomainEntry(domain: 'api.anthropic.com', origin: 'provider:a'),
            DomainEntry(domain: '*.services.example.com', origin: 'grant:g'),
          ],
        ),
      );
      final decoded = CapabilityDocument.decode(document.encode());
      expect(decoded.mode, document.mode);
      expect(decoded.workspace, document.workspace);
      expect(decoded.readDirectories, document.readDirectories);
      expect(decoded.writeDirectories, document.writeDirectories);
      expect(decoded.domains, document.domains);
      expect(decoded.rules, document.rules);
      expect(decoded.pluginGrants, document.pluginGrants);
      expect(decoded.protectedPaths, document.protectedPaths);
      expect(decoded.preopens, document.preopens);
    });

    test('rejects the failures the host rejects', () {
      final base = compileCapabilities(inputs(CapabilityMode.ask)).toJson();
      void rejects(String label, void Function(Map<String, Object?>) change) {
        final json = jsonDecode(jsonEncode(base)) as Map<String, Object?>;
        change(json);
        expect(
          () => CapabilityDocument.fromJson(json),
          throwsA(isA<CapabilityDocumentException>()),
          reason: label,
        );
      }

      rejects('bad version', (json) => json['version'] = 2);
      rejects('bad mode', (json) => json['mode'] = 'chaos');
      rejects('unknown key', (json) => json['extra'] = true);
      rejects('relative workspace', (json) => json['workspace'] = 'relative');
      rejects('bad guest name', (json) {
        (json['directories'] as Map)['read'] = [
          {'path': '/opt/sdk', 'guest': 'read 0', 'origin': 'x'}
        ];
      });
      rejects('invalid pattern', (json) {
        (json['commands'] as Map)['rules'] = [
          {'pattern': '[unclosed', 'verdict': 'allow', 'origin': 'x'}
        ];
      });
      rejects('bad domain', (json) {
        (json['network'] as Map)['domains'] = [
          {'domain': 'api..example.com', 'origin': 'x'}
        ];
      });
      rejects('unknown plugin grant', (json) {
        (json['plugins'] as Map)['grants'] = [
          {
            'plugin': 'tina/wasm-prompt',
            'grants': ['root'],
            'origin': 'x',
          }
        ];
      });
      // A grant landing on or inside a protected path is a hole.
      rejects('grant equals protected', (json) {
        json['protected_paths'] = ['/ws'];
      });
      rejects('granted under protected', (json) {
        (json['directories'] as Map)['read'] = [
          {
            'path': '/home/u/.tina/credentials.json',
            'guest': 'read-0',
            'origin': 'x',
          }
        ];
      });
      // A preopens array that disagrees with the derivation.
      rejects('preopen disagreement', (json) {
        (json['preopens'] as List).first.cast<String, Object?>()['access'] =
            'ro';
      });
    });

    test('normalizes protected paths and keeps absent leaves', () {
      final json = compileCapabilities(inputs(CapabilityMode.ask)).toJson();
      json['protected_paths'] = ['/home/u/.tina/credentials/../secrets/'];
      final decoded =
          CapabilityDocument.fromJson(json as Map<String, Object?>);
      expect(decoded.protectedPaths, ['/home/u/.tina/secrets']);
    });
  });
}
