import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina/src/config_settings_management.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/src/settings_stack.dart';
import 'package:tina/src/config_document.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';

const descriptors = [
  ProviderDescriptor(
      id: 'example',
      name: 'Example',
      wire: ProviderWire.openAiCompatible,
      baseUrl: 'https://example.test',
      keyEnvVar: 'EXAMPLE_TOKEN',
      keyStyle: ProviderKeyStyle.bearer)
];

void main() {
  late Directory root;
  late File global;
  late ScopedSettingsStack stack;
  late ConfigSettingsManagement first, second;
  ConfigSettingsManagement connect() => ConfigSettingsManagement(
      scopedSettings: stack.settings,
      backend: stack.backend,
      descriptors: descriptors,
      validatePlugins: stack.registry.validate);
  setUp(() {
    root = Directory.systemTemp.createTempSync('settings-management-');
    global = File('${root.path}/config')..writeAsStringSync('''
[default]
provider = "example"
model = "model-a"
[providers.example]
api_key = "saved-secret"
models = ["model-a|Model A", "model-b|Model B"]
legacy_private = "unknown-provider-secret"
[mcp.servers.secret]
url = "https://example.test/mcp"
enabled = false
headers = { Authorization = "mcp-secret" }
[unknown]
token = "unknown-secret"
''');
    stack = ScopedSettingsStack.build(
        globalPath: global.path,
        workspacePath: '${root.path}/workspace',
        descriptors: descriptors);
    first = connect();
    second = connect();
  });
  tearDown(() {
    first.close();
    second.close();
    stack.settings.close();
    root.deleteSync(recursive: true);
  });
  Map<String, dynamic> savedProvider() =>
      (ConfigDocument.open(global.path).values['providers'] as Map)['example']
          as Map<String, dynamic>;

  test('observer settings clients cannot write through any configuration route',
      () async {
    final host = Host.start(HostConfig(
        workingDirectory: root.path,
        providerFactory: (_) => ScriptedProvider([])));
    addTearDown(host.shutdown);
    final observer = host.connect(role: SessionRole.observer);
    final controller = host.connect();
    addTearDown(observer.close);
    addTearDown(controller.close);
    final grants = CommandApprovalStore(workspace: root.path);
    grants.remember((
      command: '/bin/echo',
      arguments: ['ok'],
      workingDirectory: root.path,
      environment: null,
      stdin: '',
      timeout: null
    ), {
      ProcessPermission.unconfined
    }, CommandApprovalScope.session);
    var applications = 0;
    ConfigSettingsManagement client(ClientAccess access) =>
        ConfigSettingsManagement(
            scopedSettings: stack.settings,
            backend: stack.backend,
            access: access,
            commandApprovals: grants,
            descriptors: descriptors,
            applyConfiguration: () => applications++);
    final read = client(observer.access), write = client(controller.access);
    addTearDown(read.close);
    addTearDown(write.close);
    final original = global.readAsStringSync();
    final draft = read.openDraft(SettingScope.global, providerCatalog: true);
    draft.editSecret('example', 'api_key', const SecretEdit.replace('blocked'));
    draft.table('providers')['example']['name'] = 'blocked';
    final snapshot = read.settings.snapshot();
    final denied = throwsA(isA<SessionAccessDenied>());
    expect(() => read.saveDraft(draft), denied);
    expect(() => read.saveGeneration(draft, 'example', {'max_output': 128}),
        denied);
    expect(
        () => read.settings.update(SettingScope.session,
            expectedRevision: snapshot.revision,
            values: {'tina/providers/requests_per_minute': 3}),
        denied);
    expect(
        () => read.settings.setInAllScopes('tina/goals/enabled', false,
            expectedRevision: snapshot.revision),
        denied);
    final grant = read.commandApprovals.single['id'] as String;
    expect(() => read.revokeCommandApproval(grant), denied);
    expect(read.refresh, denied);
    expect(applications, 0);
    expect(global.readAsStringSync(), original);
    expect(stack.settings.layer(SettingScope.session), isEmpty);
    expect(grants.entries, hasLength(1));
    expect(File(stack.backend.workspacePath).existsSync(), isFalse);
    // Read refresh cannot apply external state to the running settings owner.
    global.writeAsStringSync('$original\n[limits]\nrequests_per_minute = 9\n');
    var changes = 0;
    final stop = stack.settings.listen(() => changes++);
    addTearDown(stop);
    read.settings.snapshot(refresh: true);
    expect(changes, 0);
    write.settings.snapshot(refresh: true);
    expect(changes, greaterThan(0));
    write.revokeCommandApproval(grant);
    expect(grants.entries, isEmpty);
    final editable =
        write.openDraft(SettingScope.global, providerCatalog: true);
    controller.close();
    expect(() => write.saveDraft(editable), throwsStateError);
    expect(() => write.saveGeneration(editable, 'example', {'max_output': 64}),
        throwsStateError);
    expect(
        () => write.settings.update(SettingScope.session,
            expectedRevision: write.settings.snapshot().revision,
            values: {'tina/providers/requests_per_minute': 1}),
        throwsStateError);
  });

  test('public drafts exclude credentials and unrelated configuration', () {
    final draft = first.openDraft(SettingScope.global, providerCatalog: true);
    final text = jsonEncode(draft.values);
    expect(text, isNot(contains('secret')));
    expect(draft.hasSecret('example', 'api_key'), isTrue);
    expect(draft.secret('example', 'api_key').action, SecretAction.keep);
    draft.table('providers')['example']['name'] = 'Renamed';
    first.saveDraft(draft);
    expect(savedProvider()['api_key'], 'saved-secret');
    expect(savedProvider()['legacy_private'], 'unknown-provider-secret');
    expect(global.readAsStringSync(), contains('mcp-secret'));
    expect(global.readAsStringSync(), contains('unknown-secret'));
  });

  test('credentials explicitly replace, keep and clear', () {
    var draft = first.openDraft(SettingScope.global, providerCatalog: true);
    draft.editSecret(
        'example', 'api_key', const SecretEdit.replace('new-secret'));
    first.saveDraft(draft);
    first.closeDraft(draft);
    expect(savedProvider()['api_key'], 'new-secret');
    draft = first.openDraft(SettingScope.global, providerCatalog: true);
    draft.editSecret('example', 'api_key', const SecretEdit.keep());
    first.saveDraft(draft);
    first.closeDraft(draft);
    expect(savedProvider()['api_key'], 'new-secret');
    draft = first.openDraft(SettingScope.global, providerCatalog: true);
    draft.editSecret('example', 'api_key', const SecretEdit.clear());
    first.saveDraft(draft);
    expect(savedProvider().containsKey('api_key'), isFalse);
  });

  test('conflicting provider editors preserve the first saved change', () {
    final a = first.openDraft(SettingScope.global, providerCatalog: true);
    final b = second.openDraft(SettingScope.global, providerCatalog: true);
    a.editSecret(
        'example', 'api_key', const SecretEdit.replace('first-secret'));
    first.saveDraft(a);
    b.table('providers')['example']['name'] = 'Stale';
    expect(() => second.saveDraft(b), throwsA(isA<SettingsConflict>()));
    expect(savedProvider()['api_key'], 'first-secret');
    expect(savedProvider().containsKey('name'), isFalse);
  });

  test('external edits and session scope edits invalidate open drafts', () {
    final draft = first.openDraft(SettingScope.workspace);
    draft.table('default')['model'] = 'model-b';
    global.writeAsStringSync(global
        .readAsStringSync()
        .replaceFirst('saved-secret', 'changed-secret'));
    expect(() => first.saveDraft(draft), throwsA(isA<SettingsConflict>()));
    expect(File(stack.backend.workspacePath).existsSync(), isFalse);
    final next = first.openDraft(SettingScope.workspace);
    stack.settings.update(
        SettingScope.session, {'tina/providers/requests_per_minute': 5});
    expect(() => first.saveDraft(next), throwsA(isA<SettingsConflict>()));
  });

  test('generation saves independently and keeps a provider credential draft',
      () {
    final draft = first.openDraft(SettingScope.global, providerCatalog: true);
    draft.editSecret(
        'example', 'api_key', const SecretEdit.replace('later-secret'));
    first.saveGeneration(draft, 'example', {'max_output': 128});
    expect(savedProvider()['api_key'], 'saved-secret');
    expect(savedProvider()['max_output'], 128);
    first.saveDraft(draft);
    expect(savedProvider()['api_key'], 'later-secret');
    expect(savedProvider()['max_output'], 128);
  });

  test(
      'closed drafts cannot save and disconnect does not close shared settings',
      () {
    final draft = first.openDraft(SettingScope.global, providerCatalog: true);
    first.closeDraft(draft);
    expect(() => first.saveDraft(draft), throwsStateError);
    first.close();
    final snapshot = second.settings.snapshot(refresh: true);
    second.settings.update(SettingScope.session,
        expectedRevision: snapshot.revision,
        values: {'tina/providers/requests_per_minute': 3});
    expect(
        stack.settings
            .layer(SettingScope.session)['tina/providers/requests_per_minute'],
        3);
  });

  test('provider and secret edits cannot use a scoped model draft', () {
    final original = global.readAsStringSync();
    final draft = first.openDraft(SettingScope.workspace);
    draft.editSecret(
        'example', 'api_key', const SecretEdit.replace('new-secret'));
    expect(() => first.saveDraft(draft), throwsArgumentError);
    expect(global.readAsStringSync(), original);
    expect(File(stack.backend.workspacePath).existsSync(), isFalse);
  });

  test('an All-scopes plugin edit rejects stale state before writing any layer',
      () {
    final old = first.settings.snapshot(refresh: true);
    second.settings.update(SettingScope.session,
        expectedRevision: second.settings.snapshot(refresh: true).revision,
        values: {'tina/goals/enabled': false});
    final original = global.readAsStringSync();
    expect(
        () => first.settings.setInAllScopes('tina/goals/enabled', true,
            expectedRevision: old.revision),
        throwsA(isA<SettingsConflict>()));
    expect(global.readAsStringSync(), original);
    expect(File(stack.backend.workspacePath).existsSync(), isFalse);
    expect(stack.settings.layer(SettingScope.session)['tina/goals/enabled'],
        false);
  });
}
