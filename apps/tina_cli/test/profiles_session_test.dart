// Model profiles end to end through the assembly: the config's presets
// reach /profile, switching copies the legs into session-scoped settings
// (profiles are presets, the legs are the truth), the main leg re-points
// future requests exactly like /model, and a switch survives resume the
// way a /model switch always has. Behavioral assertions only — what the
// panels print belongs to the panel tests.
//
// Run: dart test
library;

import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';

/// Answers plain sends and structured judgments alike, so one factory
/// serves both the conversation and the classifier.
class _Judge extends LlmProvider implements StructuredOutputProvider {
  _Judge(super.model);
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      Stream.fromIterable(scriptedReply('hello'));
  @override
  Stream<StreamEvent> sendStructured(
          {required String system,
          required List<Message> messages,
          required JsonOutputSchema output}) =>
      Stream.fromIterable(scriptedReply('{"decision":"ALLOW","reason":""}'));
}

/// The config under test: a local provider, three profiles — `work` with
/// all legs, `budget` with a cheaper main and nothing else, `spawn` with
/// only a subagent leg — and `work` active from the file.
const _config = '''
version = 1
profile = "work"
[default]
provider = "local"
model = "main"
[providers.local]
base_url = "http://localhost:1234/v1"
models = ["main", "mini", "cheap", "judge"]
[profiles.work]
main = "local/main"
subagent = "local/mini"
approver = "local/judge"
[profiles.budget]
main = "local/cheap"
[profiles.spawn]
subagent = "local/mini"
''';

void main() {
  late Directory root;
  late File config;
  final requested = <String>[];
  SessionAssembly open({String? resume}) => SessionAssembly.start(
        providerFactory: (model) {
          requested.add(model);
          return _Judge(model);
        },
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: root.path,
          sessionId: resume,
        ),
      );

  setUp(() {
    requested.clear();
    root = Directory(Directory.systemTemp.createTempSync('tina-profiles-')
        .resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    config = File('${root.path}/config')..writeAsStringSync(_config);
  });

  test('switching copies the legs into session scope and re-points the model',
      () async {
    final app = open();
    addTearDown(app.close);
    Map<String, Object?> layer() => app.settings.layer(SettingScope.session);
    expect(layer(), isEmpty,
        reason: 'config-profile legs resolve on the fly; nothing is stored');

    expect(await app.handleCommand('/profile work'), isTrue);
    expect(app.host.model, 'local/main');
    expect(layer(), {
      activeProfileSetting.id: 'work',
      profileSubagentModelSetting.id: 'local/mini',
      profileApproverModelSetting.id: 'local/judge',
    }, reason: 'the main leg rides the conversation model, not a setting');

    requested.clear();
    final judgment =
        await app.tools.modePolicy.classifier!.classify({'command': 'ls'});
    expect(judgment.allow, isTrue);
    expect(requested.single, 'local/judge');
    expect(judgment.diagnostics['model'], 'local/judge');

    expect(await app.handleCommand('/profile budget'), isTrue);
    expect(app.host.model, 'local/cheap');
    expect(layer(), {activeProfileSetting.id: 'budget'},
        reason: 'a profile without a leg clears the previous copy');
    final fallback =
        await app.tools.modePolicy.classifier!.classify({'command': 'ls'});
    expect(fallback.diagnostics['model'], 'local/cheap',
        reason: 'without an approver leg the conversation model judges');
  });

  test('/model overrides the main leg without disturbing the others',
      () async {
    final app = open();
    addTearDown(app.close);
    await app.handleCommand('/profile work');
    expect(await app.handleCommand('/model local/cheap'), isTrue);
    expect(app.host.model, 'local/cheap');
    expect(app.settings.layer(SettingScope.session), {
      activeProfileSetting.id: 'work',
      profileSubagentModelSetting.id: 'local/mini',
      profileApproverModelSetting.id: 'local/judge',
    }, reason: '/model is a main-leg override; the other legs keep the copy');
    final judgment =
        await app.tools.modePolicy.classifier!.classify({'command': 'ls'});
    expect(judgment.diagnostics['model'], 'local/judge');
  });

  test('a profile that omits the main leg keeps the conversation model',
      () async {
    final app = open();
    addTearDown(app.close);
    await app.handleCommand('/profile work');
    await app.handleCommand('/model local/cheap');
    expect(await app.handleCommand('/profile spawn'), isTrue);
    expect(app.host.model, 'local/cheap',
        reason: 'no main leg: the conversation keeps its model');
    expect(app.settings.layer(SettingScope.session), {
      activeProfileSetting.id: 'spawn',
      profileSubagentModelSetting.id: 'local/mini',
    }, reason: 'the approver copy from work is cleared');
  });

  test('a switched profile and its legs survive resume', () async {
    final app = open();
    await app.host.send('first');
    await app.handleCommand('/profile work');
    await app.host.send('second');
    final id = app.host.session.id;
    await app.shutdown();

    final resumed = open(resume: id);
    addTearDown(resumed.close);
    expect(resumed.host.model, 'local/main',
        reason: 'the switched main leg persisted like a /model switch');
    expect(resumed.settings.layer(SettingScope.session), {
      activeProfileSetting.id: 'work',
      profileSubagentModelSetting.id: 'local/mini',
      profileApproverModelSetting.id: 'local/judge',
    });
    final judgment =
        await resumed.tools.modePolicy.classifier!.classify({'command': 'ls'});
    expect(judgment.diagnostics['model'], 'local/judge',
        reason: 'the approver leg is restored, not just the name');
  });
}
