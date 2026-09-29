import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:classification/plugin.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

void main() {
  test(
      'registered plugin uses Typesafe HTTP, displays staged intent and unloads live',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('classification-wiring-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    final release = Completer<void>();
    final served = <Future<void>>[];
    server.listen((request) {
      served.add(() async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        requests.add(body);
        expect(request.headers.value('authorization'),
            'Bearer fixture-classifier-key');
        expect(body['model'], 'jev-fixture');
        await release.future;
        final questions = body['questions'] as Map;
        final scores = questions.containsKey('agentInstruction')
            ? {'agentInstruction': .99}
            : {'push': .98, 'branch': .97, 'checkout': .96};
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'model': 'jev-fixture',
          'usage': {},
          'answers': {
            for (final id in questions.keys)
              id: {'type': 'noul', 'noul': scores[id] ?? 0.0}
          }
        }));
        await request.response.close();
      }());
    });
    final config = File('${directory.path}/config')..writeAsStringSync('''
[default]
model = "chat-model"
[plugins]
enabled = ["tina/classification", "tina/chat-tui", "tina/panels-tui"]
[typesafe]
api_key = "fixture-classifier-key"
model = "jev-fixture"
endpoint = "http://127.0.0.1:${server.port}/judge"
''');
    final provider = ScriptedProvider([
      [
        MessageComplete(
            content: [TextBlock('ordinary reply')], stopReason: 'end_turn')
      ]
    ]);
    final session = TuiSession.wrap(TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: directory.path),
        providerFactory: (_) => provider));
    final classifier =
        session.host.plugins.whereType<ClassificationPlugin>().single;
    final io = FakeIo();
    final app = runApp(session, screen: fakeScreen(io));
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      io.feedBytes('create a branch, check it out, then push\r'.codeUnits);
      await waitFor(() => requests.length == 1);
      // Classification does not hold up the ordinary agent response.
      await waitFor(() => session.host.session.turns.isNotEmpty);
      expect(classifier.status.phase, ClassificationPhase.checking);
      release.complete();
      await waitFor(() => classifier.status.phase == ClassificationPhase.ready);
      expect(requests, hasLength(2));
      expect(classifier.status.result!.git!.commands,
          ['push', 'branch', 'checkout']);
      expect(io.written.toString(), contains('instruction'));
      await session.assembly.handleCommand('/classification');
      expect(io.written.toString(), contains('git: push, branch, checkout'));
      final transcript = session.host.session.loop.log
          .whereType<MessageAppendedEntry>()
          .map((e) => e.message)
          .toList();
      expect(transcript, hasLength(2));
      expect((transcript.first.content.single as TextBlock).text,
          'create a branch, check it out, then push');
      session.assembly.pluginSettings.apply('tina/classification', false,
          PluginScope.session, session.assembly.pluginManager);
      expect(session.commands['classification'], isNull);
      session.assembly.pluginSettings.apply('tina/classification', true,
          PluginScope.session, session.assembly.pluginManager);
      expect(session.commands['classification'], isNotNull);
    } finally {
      if (!release.isCompleted) release.complete();
      io.feedBytes('\x03\x03\x03'.codeUnits);
      await app.timeout(const Duration(seconds: 5));
      io.closeInput();
      await server.close(force: true);
      await Future.wait(served);
      directory.deleteSync(recursive: true);
    }
  });
}
