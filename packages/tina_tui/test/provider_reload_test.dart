import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

void main() {
  late Directory directory;
  late File config;
  late HttpServer server;
  late TuiAssembly assembly;
  final requests =
      <({String path, String? authorization, Map<String, dynamic> body})>[];
  Completer<void>? holdResponse;
  Completer<void>? received;

  setUp(() async {
    requests.clear();
    holdResponse = null;
    received = null;
    directory = Directory.systemTemp.createTempSync('tina-provider-reload-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((
        path: request.uri.path,
        authorization: request.headers.value('authorization'),
        body: jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>
      ));
      received?.complete();
      received = null;
      final hold = holdResponse;
      holdResponse = null;
      if (hold != null) await hold.future;
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'answer'},
                'finish_reason': 'stop'
              }
            ],
            'usage': {'prompt_tokens': 3, 'completion_tokens': 2}
          })}\n\ndata: [DONE]\n\n');
      await request.response.close();
    });
    config = File('${directory.path}/config')..writeAsStringSync('''
[default]
provider = "local"
model = "main"
[providers.local]
name = "Existing provider"
base_url = "http://127.0.0.1:${server.port}/local/v1"
api_key = "old-fixture-key"
models = ["main|Main", "hidden|Hidden"]
disabled_models = ["hidden"]
[plugins]
selection_version = 2
enabled = ["tina/providers", "tina/session-controls"]
''');
    assembly = TuiAssembly.start(
        descriptors: [],
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: directory.path));
  });
  tearDown(() async {
    assembly.close();
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });

  final enter = ControlKey(ControlCode.enter);
  final down = ArrowKey(ArrowDirection.down);
  final right = ArrowKey(ArrowDirection.right);
  final escape = EscapeKey();

  Future<bool> settings(List<InputEvent> keys) async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final editor = LineEditor(screen: screen);
    var index = 0;
    final panel = SettingsPanel(screen, editor, readEvent: () async {
      if (index >= keys.length) fail('settings requested an unexpected key');
      return keys[index++];
    });
    try {
      final saved = await panel.run(
          path: config.path,
          descriptors: assembly.descriptors,
          applyConfiguration: assembly.applySavedConfiguration);
      expect(index, keys.length);
      return saved;
    } finally {
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  }

  Future<List<String>> completions(TuiAssembly app) async =>
      await app.commands['model']!.complete!('');

  test(
      'saving a new provider updates picker, completion, open panels and requests',
      () async {
    final panel = assembly.newSession(null);
    addTearDown(panel.close);
    final id = assembly.host.session.id;
    await assembly.host.send('remember this');
    expect(requests.single.authorization, 'Bearer old-fixture-key');
    expect(await completions(assembly), ['local/main']);

    expect(
        await settings([
          CharInput('Providers and models'), enter,
          down, enter, // Add provider
          PasteInput('custom'), enter,
          down, PasteInput('new-fixture-key'), // API key
          down, PasteInput('http://127.0.0.1:${server.port}/custom/v1'), // URL
          down, down, enter, // Add model
          PasteInput('org/new-model|Live custom model'), enter,
          enter, // Apply tree draft
          CharInput('Save'), enter,
        ]),
        true);
    expect(assembly.host.model, 'local/main');
    expect(assembly.host.session.id, id);
    for (final app in [assembly, panel]) {
      expect(await completions(app), ['local/main', 'custom/org/new-model']);
    }

    // Exercise the real /model picker after saving, rather than switching only
    // through the command argument or inspecting a configuration object.
    final io = FakeIo();
    final screen = fakeScreen(io);
    final editor = LineEditor(screen: screen);
    final controls =
        assembly.host.plugins.whereType<SessionControlsPlugin>().single;
    final attachment = ConsoleAttachment.attach(
        controls, ConsoleContext(screen: screen, editor: editor));
    try {
      final pick = assembly.handleCommand('/model');
      await waitFor(() => editor.isReadingKey);
      expect(io.written.toString(), contains('org/new-model'));
      editor.inject(PasteInput('Live custom model'));
      await waitFor(
          () => io.written.toString().contains('Live custom model'));
      editor.inject(enter);
      await pick;
      expect(assembly.host.model, 'custom/org/new-model');
    } finally {
      attachment.dispose();
      editor.close();
      screen.dispose();
      io.closeInput();
    }
    await assembly.host.send('use the new provider');
    expect(requests.last.path, '/custom/v1/chat/completions');
    expect(requests.last.authorization, 'Bearer new-fixture-key');
    expect(requests.last.body['model'], 'org/new-model');
    expect((requests.last.body['messages'] as List).length, greaterThan(2));
    expect(assembly.host.session.id, id);
    expect(
        assembly.host.plugins
            .whereType<ProviderPolicyPlugin>()
            .single
            .sessionTokens,
        10);

    // Dynamically enabling the controls plugin must use the refreshed source.
    panel.pluginSettings.apply('tina/session-controls', false,
        PluginScope.session, panel.pluginManager);
    panel.pluginSettings.apply('tina/session-controls', true,
        PluginScope.session, panel.pluginManager);
    expect(await completions(panel), contains('custom/org/new-model'));
    await panel.handleCommand('/model custom/org/new-model');
    final child = panel.host.plugins
        .whereType<ProviderPolicyPlugin>()
        .single
        .childProvider(panel.host.model);
    try {
      await child.send(system: '', messages: [], tools: []).drain<void>();
      expect(requests.last.path, '/custom/v1/chat/completions');
      expect(requests.last.body['model'], 'org/new-model');
    } finally {
      child.close();
    }
    final newPanel = assembly.newSession(null);
    try {
      expect(await completions(newPanel), contains('custom/org/new-model'));
      expect(newPanel.host.model, 'custom/org/new-model');
    } finally {
      newPanel.close();
    }
  });

  test(
      'adding and enabling models takes effect on save; Escape discards drafts',
      () async {
    expect(
        await settings([
          CharInput('Providers and models'), enter,
          right,
          down, down, down, down, down, // Hidden
          CharInput(' '), // Enable Hidden
          down, enter, // Add model
          PasteInput('another|Another model'), enter,
          enter,
          CharInput('Save'), enter,
        ]),
        true);
    expect(await completions(assembly),
        ['local/main', 'local/hidden', 'local/another']);
    await assembly.handleCommand('/model local/another');
    await assembly.host.send('new model');
    expect(requests.single.body['model'], 'another');

    final before = config.readAsStringSync();
    expect(
        await settings([
          CharInput('Providers and models'),
          enter,
          right,
          down,
          down,
          down,
          down,
          down,
          down,
          down,
          enter,
          PasteInput('discarded|Discard me'),
          enter,
          escape,
          escape,
        ]),
        false);
    expect(config.readAsStringSync(), before);
    expect(await completions(assembly), isNot(contains('local/discarded')));
  });

  test(
      'saving endpoint and credentials during a response applies to the next request',
      () async {
    final hold = Completer<void>();
    holdResponse = hold;
    received = Completer<void>();
    final requestReceived = received!.future;
    final inFlight = assembly.host.send('first');
    try {
      await requestReceived;
      final document = ConfigDocument.open(config.path);
      final provider =
          document.table('providers')['local'] as Map<String, dynamic>;
      provider['api_key'] = 'updated-fixture-key';
      provider['base_url'] = 'http://127.0.0.1:${server.port}/updated/v1';
      document.save(descriptors: assembly.descriptors);
      assembly.applySavedConfiguration();
      expect(assembly.host.session.loop.inTurn, true);
      expect(requests.single.authorization, 'Bearer old-fixture-key');
      hold.complete();
      await inFlight;
      expect(assembly.host.session.lastReply, 'answer');
      await assembly.host.send('second');
      expect(requests.last.path, '/updated/v1/chat/completions');
      expect(requests.last.authorization, 'Bearer updated-fixture-key');
      expect(assembly.host.model, 'local/main');
    } finally {
      if (!hold.isCompleted) hold.complete();
      await inFlight;
    }
  });
}

Future<void> waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline))
      fail('timed out waiting for the picker');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
