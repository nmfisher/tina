import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:classification/plugin.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

class _Call {
  _Call(this.model, this.system, this.messages, this.output);
  final String model, system;
  final List<Message> messages;
  final JsonOutputSchema? output;
}

class _LearningModel extends LlmProvider implements StructuredOutputProvider {
  _LearningModel(super.model, this.calls);
  final List<_Call> calls;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    calls.add(_Call(model, system, messages, null));
    return Stream.value(const MessageComplete(
        content: [TextBlock('ordinary reply')],
        stopReason: 'end_turn',
        usage: TokenUsage(
            inputTokens: 3,
            outputTokens: 2,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0)));
  }

  @override
  Stream<StreamEvent> sendStructured(
      {required String system,
      required List<Message> messages,
      required JsonOutputSchema output}) {
    calls.add(_Call(model, system, messages, output));
    return Stream.value(const MessageComplete(
        content: [
          TextBlock(
              '{"existing_category":null,"category":{"id":"greeting","label":"greeting",'
              '"description":"A conversational greeting.","question":"Is the latest input a greeting?"}}')
        ],
        stopReason: 'end_turn',
        usage: TokenUsage(
            inputTokens: 8,
            outputTokens: 4,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0)));
  }
}

class _Output implements Terminal {
  final lines = <String?>[];
  @override
  void writeln([String? line]) => lines.add(line);
  @override
  Future<String> ask(String prompt) async => throw UnimplementedError();
}

void main() {
  test(
      'Other queries the active model in isolation and persists learning across workspaces',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('classification-learning-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final judgments = <Map<String, dynamic>>[];
    final served = <Future<void>>[];
    server.listen((request) {
      served.add(() async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        judgments.add(body);
        final question = (body['questions'] as Map)['intent'] as Map;
        final choices = question['criteria'] as Map;
        final selected = choices.containsKey('greeting') ? 'greeting' : 'other';
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'model': 'jev-fixture',
          'usage': {},
          'answers': {
            'intent': {
              'type': 'choice',
              'choice': selected,
              'confidence': .99,
              'probabilities': {
                for (final key in choices.keys) key: key == selected ? 1.0 : 0.0
              },
            }
          },
        }));
        await request.response.close();
      }());
    });
    final config = File('${directory.path}/config')..writeAsStringSync('''
[default]
model = "active-chat-model"
[plugins]
enabled = ["tina/classification"]
[typesafe]
api_key = "fixture-classifier-key"
model = "jev-fixture"
endpoint = "http://127.0.0.1:${server.port}/judge"
''');
    final calls = <_Call>[];
    final output = _Output();
    TuiSession? current;
    try {
      for (final project in ['first', 'second']) {
        final workspace = Directory('${directory.path}/$project')..createSync();
        current = TuiSession.wrap(TuiAssembly.start(
          terminal: output,
          options: AssemblyOptions(
              configPath: config.path, workingDirectory: workspace.path),
          providerFactory: (model) => _LearningModel(model, calls),
        ));
        final plugin =
            current.host.plugins.whereType<ClassificationPlugin>().single;
        await current.runLine('hello $project', renderReply: false);
        await waitFor(() => plugin.status.phase == ClassificationPhase.ready);
        expect(plugin.status.label, 'greeting');
        final transcript = current.host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .toList();
        expect(transcript, hasLength(2),
            reason: 'discovery is not part of the conversation');
        expect((transcript.last.message.content.single as TextBlock).text,
            'ordinary reply');
        final root = (await plugin.categories.read()).first;
        expect(root.categories, hasLength(3));
        expect(
            root.category('greeting')!.selections, project == 'first' ? 1 : 2);
        expect(root.otherSelections, 1);
        if (project == 'first') {
          expect(
              current.host.plugins
                  .whereType<ProviderPolicyPlugin>()
                  .single
                  .sessionTokens,
              17,
              reason:
                  'isolated discovery still obeys and charges normal provider policy');
        }
        await current.assembly.handleCommand('/classification categories');
        expect(output.lines.join('\n'), contains('greeting: greeting'));
        current.close();
        current = null;
      }
      expect(judgments, hasLength(3)); // Other, retry, next workspace.
      final fresh = calls.where((call) => call.output != null).single;
      expect(fresh.model, 'active-chat-model');
      expect(fresh.messages, hasLength(1));
      final evidence = (fresh.messages.single.content.single as TextBlock).text;
      expect(evidence, contains('hello first'));
      expect(evidence, isNot(contains('ordinary reply')));
      expect(evidence, isNot(contains('hello second')));
      expect(fresh.system, contains('Do not carry out the task'));
      expect(
          File('${directory.path}/classification/categories.json').existsSync(),
          true);
    } finally {
      current?.close();
      await server.close(force: true);
      await Future.wait(served);
      directory.deleteSync(recursive: true);
    }
  });

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
        final scores = {'push': .98, 'branch': .97, 'checkout': .96};
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'model': 'jev-fixture',
          'usage': {},
          'answers': {
            for (final id in questions.keys)
              id: id == 'intent'
                  ? {
                      'type': 'choice',
                      'choice': 'agentInstruction',
                      'confidence': .99,
                      'probabilities': {
                        'projectQuestion': .01,
                        'agentInstruction': .99,
                        'other': 0.0
                      },
                    }
                  : {'type': 'noul', 'noul': scores[id] ?? 0.0}
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
      expect(classifier.trace.exchanges.single.phase,
          ClassificationExchangePhase.pending);
      expect(jsonDecode(classifier.trace.exchanges.single.request),
          requests.single);
      expect(io.written.toString(), contains('classification'));
      expect(io.written.toString(), isNot(contains('intent: classifying')));
      release.complete();
      await waitFor(() => classifier.status.phase == ClassificationPhase.ready);
      expect(requests, hasLength(2));
      expect(classifier.trace.exchanges, hasLength(2));
      expect(classifier.trace.exchanges.last.parentId,
          classifier.trace.exchanges.first.id);
      expect(
          jsonDecode(classifier.trace.exchanges.last.request), requests.last);
      expect(
          jsonDecode(classifier.trace.exchanges.last.response)['answers']
              ['push']['noul'],
          .98);
      expect(classifier.status.result!.git!.commands,
          ['push', 'branch', 'checkout']);
      expect(io.written.toString(), contains('instruction'));
      await session.assembly.handleCommand('/classification');
      expect(
          classifier.status.label, 'instruction · git: push, branch, checkout');
      expect(io.written.toString(), contains('Git operations'));
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
