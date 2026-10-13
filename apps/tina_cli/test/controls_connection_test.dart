import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina/src/snapshot_catalog.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

class _Terminal implements Terminal {
  @override
  void writeln([String? text]) {}
  @override
  Future<String> ask(String prompt) => throw UnimplementedError();
}

class _Session {
  _Session({LlmProvider? provider}) {
    mode = ModePlugin();
    controls = newControls();
    host = Host.start(
      HostConfig(
        workingDirectory: '.',
        model: 'acme/one',
        plugins: [mode, controls],
        providerFactory: (model) {
          if (model == 'acme/bad') throw StateError('private provider failure');
          return provider ?? ScriptedProvider([scriptedReply('answer')]);
        },
        snapshotFeatureFor: snapshotFeatureFor,
        operationsFor: (plugin) => plugin is ModePolicySource
            ? modeOperations
            : sessionControlsOperations,
      ),
    );
    addTearDown(host.shutdown);
  }
  late final Host host;
  late final ModePlugin mode;
  late final SessionControlsPlugin controls;
  final models = ['acme/one', 'acme/two', 'acme/three', 'acme/bad'];
  SessionControlsPlugin newControls() => SessionControlsPlugin(
    terminal: _Terminal(),
    currentModel: () => host.model,
    switchModel: (value) => host.switchModel(value),
    modelCatalog: () => ModelCatalog(
      models: models,
      providerNames: const {'acme': 'Acme'},
      modelNames: const {'acme/two': 'Second model'},
    ),
  );
}

class _Views {
  _Views(_Session session, {SessionRole role = SessionRole.controller})
    : connection = session.host.connect(role: role) {
    mode = createConsoleView(session.mode, connection: connection)! as ModeView;
    models =
        createConsoleView(session.controls, connection: connection)!
            as SessionControlsView;
    attach();
    addTearDown(close);
  }
  final SessionConnection connection;
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  late final console = ConsoleContext(screen: screen, editor: editor);
  late final ModeView mode;
  late final SessionControlsView models;
  final attachments = <ConsoleAttachment>[];
  void attach() {
    attachments.addAll([
      ConsoleAttachment.attach(mode, console),
      ConsoleAttachment.attach(models, console),
    ]);
  }

  void detach() {
    for (final attachment in attachments) attachment.dispose();
    attachments.clear();
  }

  void close() {
    detach();
    connection.close();
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

Future<SessionRequestSnapshot> _set(
  SessionConnection connection,
  String key,
  String plugin,
  String operation,
  Map<String, Object?> arguments,
) => connection
    .submitOperation(
      plugin,
      operation,
      arguments: arguments,
      id: connection.requestWindow.id(key),
    )
    .completed;

void main() {
  test(
    'two controllers and an observer share snapshots and retryable controls',
    () async {
      final session = _Session();
      final first = _Views(session), second = _Views(session);
      final observer = _Views(session, role: SessionRole.observer);
      expect(first.models.controls, isNot(same(second.models.controls)));
      expect(first.models.controls.catalog.models, session.models);
      expect(
        () => first.models.controls.catalog.models.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => first.models.controls.catalog.providerNames.clear(),
        throwsUnsupportedError,
      );
      expect(observer.models.controls.canControl, false);
      expect(observer.mode.mode.canControl, false);
      await expectLater(
        observer.models.controls.select('acme/two', expectedModel: 'acme/one'),
        throwsA(isA<SessionAccessDenied>()),
      );
      await expectLater(
        observer.mode.mode.setMode(
          PermissionMode.auto,
          expectedMode: PermissionMode.ask,
        ),
        throwsA(isA<SessionAccessDenied>()),
      );
      expect(
        () => observer.connection.submitOperation(
          'tina/mode',
          'set',
          arguments: {'mode': 'auto', 'expected_mode': 'ask'},
          id: observer.connection.requestWindow.id('denied'),
        ),
        throwsA(isA<SessionAccessDenied>()),
      );

      final id = first.connection.requestWindow.id('model-selection');
      final request = first.connection.submitOperation(
        'tina/session-controls',
        'select-model',
        arguments: {'model': 'acme/two', 'expected_model': 'acme/one'},
        id: id,
      );
      expect((await request.completed).state, SessionRequestState.completed);
      await waitFor(() => observer.models.controls.currentModel == 'acme/two');
      expect(second.models.controls.recentModels, ['acme/two']);
      expect(
        () => second.models.controls.recentModels.clear(),
        throwsUnsupportedError,
      );
      first.detach();
      await second.models.controls.select(
        'acme/three',
        expectedModel: 'acme/two',
      );
      expect(
        second.connection.submitOperation(
          'tina/session-controls',
          'select-model',
          arguments: {'expected_model': 'acme/one', 'model': 'acme/two'},
          id: id,
        ),
        same(request),
      );
      expect(
        session.host.model,
        'acme/three',
        reason: 'An old retry cannot apply again',
      );
      await second.mode.mode.setMode(
        PermissionMode.readOnly,
        expectedMode: PermissionMode.ask,
      );
      await waitFor(() => observer.mode.mode.mode == PermissionMode.readOnly);
      first.attach();
      expect(first.models.controls.currentModel, 'acme/three');
      expect(first.mode.mode.mode, PermissionMode.readOnly);
      expect(session.host.plugins.any((p) => p.id == 'tina/chat-tui'), false);
    },
  );

  test(
    'an open picker cannot overwrite another client or select a removed model',
    () async {
      final session = _Session();
      final first = _Views(session), second = _Views(session);
      final pick = first.models.handleConsoleCommand('model', '')!;
      await waitFor(() => first.editor.isReadingKey);
      await second.models.controls.select(
        'acme/three',
        expectedModel: 'acme/one',
      );
      first.editor.inject(PasteInput('Second model'));
      first.editor.inject(ControlKey(ControlCode.enter));
      await expectLater(
        pick,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('another client'),
          ),
        ),
      );
      expect(session.host.model, 'acme/three');

      final removed = first.models.handleConsoleCommand('model', '')!;
      await waitFor(() => first.editor.isReadingKey);
      session.models.remove('acme/two');
      session.host.refreshSnapshot();
      first.editor.inject(PasteInput('Second model'));
      first.editor.inject(ControlKey(ControlCode.enter));
      await expectLater(
        removed,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no longer available'),
          ),
        ),
      );
      expect(session.host.model, 'acme/three');
      expect(session.controls.observation.recentModels, ['acme/three']);
    },
  );

  test(
    'mode changes during a live turn while model changes stay blocked',
    () async {
      final provider = ControlledProvider();
      final session = _Session(provider: provider);
      final first = _Views(session), second = _Views(session);
      final turn = session.host.send('continue after detach');
      await waitFor(() => provider.requests.isNotEmpty);
      final work = first.connection.attach();
      final originalWork = work.initial.activeWork.single.id;
      work.close();
      await first.mode.mode.setMode(
        PermissionMode.auto,
        expectedMode: PermissionMode.ask,
      );
      await waitFor(() => second.mode.mode.mode == PermissionMode.auto);
      final rejected = await _set(
        second.connection,
        'busy-model',
        'tina/session-controls',
        'select-model',
        {'model': 'acme/two', 'expected_model': 'acme/one'},
      );
      expect(rejected.state, SessionRequestState.rejected);
      expect(session.host.model, 'acme/one');
      first.detach();
      first.connection.close();
      expect(session.host.session.loop.running, true);
      final after = second.connection.attach();
      expect(after.initial.activeWork.single.id, originalWork);
      after.close();
      provider.requests.single.add(
        const MessageComplete(
          content: [TextBlock('finished')],
          stopReason: 'end_turn',
        ),
      );
      await provider.requests.single.close();
      await turn;
      expect(
        session.host.session.loop.log
            .whereType<PluginStateEntry>()
            .single
            .value,
        {'mode': 'auto'},
      );
      expect(second.connection.status.busy, false);
    },
  );

  test(
    'invalid and stale controls leave policy and providers unchanged',
    () async {
      final session = _Session();
      final view = _Views(session);
      await view.mode.mode.setMode(
        PermissionMode.auto,
        expectedMode: PermissionMode.ask,
      );
      for (final args in [
        {'mode': 'allowEdits', 'expected_mode': 'ask'},
        {'mode': 'unknown', 'expected_mode': 'auto'},
        {'mode': 'ask'},
        {'mode': 'ask', 'expected_mode': 'auto', 'allowWhileRunning': true},
      ]) {
        expect(
          (await _set(
            view.connection,
            'invalid-mode-${args.hashCode}',
            'tina/mode',
            'set',
            args,
          )).state,
          SessionRequestState.failed,
        );
      }
      expect(session.mode.mode, PermissionMode.auto);
      for (final args in [
        {'model': 'unknown', 'expected_model': 'acme/one'},
        {'model': 'acme/two', 'expected_model': 'old'},
        {'model': 'acme/two'},
        {'model': 2, 'expected_model': 'acme/one'},
        {'model': 'acme/two', 'expected_model': 'acme/one', 'extra': true},
        {'model': 'acme/bad', 'expected_model': 'acme/one'},
      ]) {
        final result = await _set(
          view.connection,
          'invalid-model-${args.hashCode}',
          'tina/session-controls',
          'select-model',
          args,
        );
        expect(result.state, SessionRequestState.failed);
        expect(
          result.result!.detail,
          isNot(contains('private provider failure')),
        );
      }
      expect(session.host.model, 'acme/one');
      expect(session.controls.observation.recentModels, isEmpty);
      expect(
        (await session.host.send('old provider still usable')).stopReason,
        StopReason.complete,
      );
    },
  );

  test(
    'unload and reload disable old controls and recover current snapshots',
    () async {
      final session = _Session();
      final first = _Views(session), second = _Views(session);
      await first.mode.mode.setMode(
        PermissionMode.readOnly,
        expectedMode: PermissionMode.ask,
      );
      final pick = first.models.handleConsoleCommand('model', '')!;
      await waitFor(() => first.editor.isReadingKey);
      session.host.detachPlugin('tina/session-controls');
      await waitFor(() => !second.models.controls.available);
      first.editor.inject(PasteInput('Second model'));
      first.editor.inject(ControlKey(ControlCode.enter));
      await expectLater(pick, throwsStateError);
      expect(session.host.model, 'acme/one');
      session.host.detachPlugin('tina/mode');
      await waitFor(() => !second.mode.mode.available);
      expect(second.io.written.toString(), contains('mode: unavailable'));
      expect(
        (await _set(second.connection, 'unloaded-mode', 'tina/mode', 'set', {
          'mode': 'ask',
          'expected_mode': 'readOnly',
        })).state,
        SessionRequestState.rejected,
      );
      final replacement = ModePlugin();
      session.host.attachPlugin(replacement);
      session.host.attachPlugin(session.newControls());
      await waitFor(
        () => second.mode.mode.available && second.models.controls.available,
      );
      expect(second.mode.mode.mode, PermissionMode.readOnly);
      await second.models.controls.select(
        'acme/two',
        expectedModel: 'acme/one',
      );
      expect(
        session.controls.observation.recentModels,
        isEmpty,
        reason: 'No operation retained the unloaded plugin',
      );
      expect(
        session.host.plugins
            .whereType<SessionControlsPlugin>()
            .single
            .observation
            .recentModels,
        ['acme/two'],
      );
    },
  );

  test(
    'connection changes persist through session resume without changing defaults',
    () async {
      final root = Directory.systemTemp.createTempSync('controls-resume-');
      addTearDown(() => root.deleteSync(recursive: true));
      final config = File('${root.path}/config')
        ..writeAsStringSync('''
[default]
provider = "local"
model = "one"
[providers.local]
api_key = "fixture-secret"
base_url = "https://example.invalid/v1"
models = ["one", "two"]
[plugins]
enabled = ["tina/session-controls", "tina/mode", "tina/persistence"]
''');
      final original = config.readAsStringSync();
      SessionAssembly open({String? resume}) => SessionAssembly.start(
        providerFactory: (_) => ScriptedProvider([scriptedReply('answer')]),
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: root.path,
          sessionId: resume,
        ),
      );
      final app = open();
      final id = app.host.session.id;
      final client = app.host.connect();
      final models = ConnectionSessionControls(client)..refresh();
      final mode = ConnectionModeObservation(client)..refresh();
      expect(models.currentModel, 'one');
      await models.select('local/two', expectedModel: models.currentModel);
      await mode.setMode(
        PermissionMode.allowEdits,
        expectedMode: PermissionMode.ask,
      );
      final snapshot = client.attach();
      expect(
        snapshot.initial.features.toString(),
        isNot(contains('fixture-secret')),
      );
      snapshot.close();
      client.close();
      await app.shutdown();
      final resumed = open(resume: id);
      addTearDown(resumed.shutdown);
      expect(resumed.host.model, 'local/two');
      expect(resumed.tools.mode, PermissionMode.allowEdits);
      expect(config.readAsStringSync(), original);
    },
  );

  test(
    'failed publication disables both controls and keeps the old policy',
    () async {
      final session = _Session();
      final first = _Views(session), second = _Views(session);
      final broken = session.host.session.loop.subscribe((entry, event) {
        if (event == LogEvent.appended)
          throw StateError('private storage failure');
      });
      addTearDown(() => session.host.session.loop.unsubscribe(broken));
      final result = await _set(
        first.connection,
        'failed-mode',
        'tina/mode',
        'set',
        {'mode': 'auto', 'expected_mode': 'ask'},
      );
      expect(result.state, SessionRequestState.failed);
      expect(result.result!.detail, isNot(contains('private storage failure')));
      expect(session.mode.mode, PermissionMode.ask);
      await waitFor(
        () => !second.mode.mode.available && !second.models.controls.available,
      );
      expect(second.mode.mode.canControl, false);
      expect(second.models.controls.canControl, false);
      await expectLater(
        second.models.controls.select('acme/two', expectedModel: 'acme/one'),
        throwsStateError,
      );
      expect(session.host.model, 'acme/one');
    },
  );
}
