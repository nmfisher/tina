import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_capability/tina_capability.dart';

import 'package:tina/src/engine_launcher.dart';

void main() {
  late Directory configDir;
  late Directory workspace;

  setUp(() {
    configDir = Directory.systemTemp.createTempSync('tina-cap-launch');
    workspace = Directory.systemTemp.createTempSync('tina-cap-ws');
    Directory(p.join(configDir.path, 'approvals')).createSync();
  });

  tearDown(() {
    configDir.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  void writeStore(String name, List<Map<String, Object?>> grants) {
    File(p.join(configDir.path, 'approvals', name)).writeAsStringSync(
      jsonEncode({'version': 1, 'grants': grants}),
    );
  }

  test('standing grants fold into the compiled document', () {
    writeStore('permissions.json', [
      {
        'kind': 'setting',
        'id': 'setting:global:x:tina/tools/read_only_directories',
        'scope': 'global',
        'setting': 'tina/tools/read_only_directories',
        'value': ['/opt/custom-sdk'],
        'command': 'read only directories',
        'directory': '/opt/custom-sdk',
      },
      {
        'kind': 'setting',
        'id': 'setting:global:x:tina/tools/write_directories',
        'scope': 'global',
        'setting': 'tina/tools/write_directories',
        'value': ['/projects/related'],
        'command': 'write directories',
        'directory': '/projects/related',
      },
    ]);
    writeStore('commands.json', [
      {
        'id': 'git-status-1',
        'scope': 'global',
        'pattern': 'git status',
        'command': 'git status',
        'executable': 'git',
        'profile_version': 2,
      },
      {
        'id': 'net-1',
        'scope': 'global',
        'capability': 'network',
        'target': 'telemetry.example.net',
        'decided_by': 'user',
      },
    ]);

    final inputs = readCapabilityInputs(
      workspace: workspace.path,
      configDir: configDir.path,
      yolo: false,
      environment: const {
        'TINA_LLM_ENDPOINT': 'https://llm.internal.example/v1',
        'ANTHROPIC_API_KEY': 'sk-test',
      },
    );

    expect(inputs.mode, CapabilityMode.ask);
    expect(inputs.readDirectories, ['/opt/custom-sdk']);
    expect(inputs.writeDirectories, ['/projects/related']);
    expect(
      inputs.rules.map((r) => (r.pattern, r.origin)),
      [('git status', 'grant:git-status-1')],
    );
    final domainStrings = inputs.domains.map((d) => d.domain).toSet();
    expect(domainStrings, containsAll(['telemetry.example.net', 'llm.internal.example', 'api.anthropic.com']));

    final document = compileCapabilities(inputs);
    expect(
      document.readDirectories.single.guest,
      startsWith('read-'),
    );
    expect(
      document.rules.single.verdict,
      CommandVerdict.allow,
    );
    expect(document.domains.map((d) => d.domain), contains('llm.internal.example'));
  });

  test('a fresh install compiles the structural-only document', () {
    final inputs = readCapabilityInputs(
      workspace: workspace.path,
      configDir: configDir.path,
      yolo: false,
    );
    expect(inputs.readDirectories, isEmpty);
    expect(inputs.rules, isEmpty);
    final document = compileCapabilities(inputs);
    expect(document.writeDirectories.map((d) => d.guest), ['.', 'config']);
    expect(document.readDirectories, isEmpty);
    expect(document.rules, isEmpty);
  });

  test('argv carries --capabilities instead of preopens', () {
    final argv = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: workspace.path,
      configPath: p.join(configDir.path, 'config'),
      yolo: false,
      capabilitiesPath: p.join(configDir.path, 'capabilities.json'),
    );
    expect(argv.where((a) => a.startsWith('--capabilities=')), hasLength(1));
    expect(argv.where((a) => a.startsWith('--preopen=')), isEmpty,
        reason: 'the document carries the preopen structure');
    expect(argv, contains('--env=TINA_ENGINE_YOLO=0'));
  });

  test('argv without a document keeps the legacy preopen flags', () {
    final argv = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: workspace.path,
      configPath: p.join(configDir.path, 'config'),
      yolo: false,
    );
    expect(argv, contains('--preopen=.=${p.normalize(p.absolute(workspace.path))}'));
    expect(
        argv, contains('--preopen=config=${p.normalize(p.absolute(configDir.path))}'));
    expect(argv.where((a) => a.startsWith('--capabilities=')), isEmpty);
  });

  test('an out-of-workspace store rides the document, not a flag', () {
    final store = Directory.systemTemp.createTempSync('tina-cap-store');
    addTearDown(store.deleteSync);
    final argv = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: workspace.path,
      configPath: p.join(configDir.path, 'config'),
      storePath: p.join(store.path, 'sessions.jsonl'),
      yolo: false,
      capabilitiesPath: p.join(configDir.path, 'capabilities.json'),
    );
    expect(argv, contains('--env=TINA_ENGINE_STORE=store/sessions.jsonl'));
    expect(argv.where((a) => a.startsWith('--preopen=')), isEmpty);
  });
}
