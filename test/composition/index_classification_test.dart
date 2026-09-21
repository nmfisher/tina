import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tina/composition/typesafe.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_app/classification.dart'
    show ProjectClassificationReport, SqliteClassificationStore;
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_environment.dart';
import '../helpers/memory_session_store.dart';

class Client extends MockClient {
  bool closed = false;
  Client(super.handler);
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  late Directory temp;
  late Directory project;
  late AppComposition app;
  final env = <String, String>{};
  final clients = <Client>[];
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? respond;
  http.Client client() {
    final result = Client((request) async {
      requests.add(request);
      if (respond != null) return respond!(request);
      final body = jsonDecode(request.body) as Map;
      return http.Response(
        jsonEncode({
          'model': '${body['model']}-resolved',
          'usage': {'input_tokens': 200, 'output_tokens': 100},
          'answers': {
            for (final id in (body['questions'] as Map).keys)
              id: {
                'type': 'noul',
                'noul': const ['dart', 'python'].contains(id) ? 0.99 : 0.01,
              },
          },
        }),
        200,
      );
    });
    clients.add(result);
    return result;
  }

  Future<void> settings({
    String key = 'saved-key',
    String model = 'jev-pinned',
  }) => File(
    '${temp.path}/config',
  ).writeAsString('[typesafe]\napi_key = "$key"\nmodel = "$model"\n');
  Future<ProjectClassificationReport> run({
    LanguageMethod method = LanguageMethod.jev,
    String mode = '',
    Future<void>? cancel,
  }) => runConfiguredProjectClassification(
    app,
    method: method,
    mode: mode,
    tinaDir: temp,
    clientFactory: client,
    cancelSignal: cancel,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('typesafe-index-');
    project = await Directory('${temp.path}/project').create();
    await Process.run('git', ['init', '-q', project.path]);
    await File(
      '${project.path}/main.dart',
    ).writeAsString('SECRET FILE CONTENT NOT SENT');
    await File(
      '${project.path}/script.py',
    ).writeAsString('SECOND CONTENT NOT SENT');
    env.clear();
    clients.clear();
    requests.clear();
    respond = null;
    final registry = ProviderRegistry(env: const {})
      ..register(
        ProviderDescriptor(
          id: 'chat',
          name: 'Chat',
          authSources: const [],
          defaultBaseUrl: 'https://chat.invalid',
          builder: (_) =>
              throw StateError('/index constructed a chat provider'),
        ),
      );
    app = await buildAppComposition(
      config: RuntimeConfig(
        provider: 'chat',
        model: 'chat-model',
        reasoningEffort: 'high',
      ),
      registry: registry,
      store: MemorySessionStore(),
      environment: FakeEnvironment(env: env),
      projectRoot: project.path,
      loadProjectContext: false,
    );
  });
  tearDown(() async {
    await app.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'extensions need no key or HTTP and never reuse JEV results as local rules',
    () async {
      final first = await runConfiguredProjectClassification(
        app,
        tinaDir: temp,
        clientFactory: () => throw StateError(
          'Default /index must not construct an HTTP client',
        ),
      );
      expect(
        first.failures.keys,
        unorderedEquals(['.::framework', '.::tooling']),
      );
      expect(
        first.records['.::language']!.result.value!.labels.map((l) => l.value),
        ['dart', 'python'],
      );
      expect(requests, isEmpty);
      expect(clients, isEmpty);
      expect(
        (await run(method: LanguageMethod.extensions, mode: 'status')).restored,
        2,
      );
      await settings();
      final modeled = await run(method: LanguageMethod.jev);
      expect(modeled.failures, isEmpty);
      expect(modeled.executed, 1);
      expect(requests, hasLength(1));
      final local = await run(method: LanguageMethod.extensions);
      expect(local.failures, isEmpty);
      expect(local.executed, 1);
      expect(requests, hasLength(1));
      expect(
        (await run(
          method: LanguageMethod.extensions,
          mode: 'refresh',
        )).executed,
        1,
      );
      expect(requests, hasLength(1));
    },
  );

  test(
    'default index stores model framework and tooling results beside local languages',
    () async {
      await settings();
      await File('${project.path}/requirements.txt').writeAsString('fastapi');
      await File('${project.path}/Dockerfile').writeAsString('FROM python:3');
      respond = (request) async {
        final body = jsonDecode(request.body) as Map;
        return http.Response(
          jsonEncode({
            'model': 'jev-test',
            'usage': {'input_tokens': 100, 'output_tokens': 50},
            'answers': {
              for (final id in (body['questions'] as Map).keys)
                id: {
                  'type': 'noul',
                  'noul': ['fastapi', 'docker'].contains(id) ? 0.99 : 0.01,
                },
            },
          }),
          200,
        );
      };
      final result = await run(method: LanguageMethod.extensions);
      expect(result.failures, isEmpty);
      expect(
        result.records.keys,
        containsAll(['.::language', '.::framework', '.::tooling']),
      );
      expect(
        result.records['.::framework']!.result.value!.labels.single.value,
        'fastapi',
      );
      expect(
        result.records['.::tooling']!.result.value!.labels.single.value,
        'docker',
      );
      expect(requests, hasLength(2));
      expect(
        requests.every((r) => !r.body.contains('SECRET FILE CONTENT')),
        isTrue,
      );
      expect(
        (await run(method: LanguageMethod.extensions, mode: 'status')).failures,
        isEmpty,
      );
      expect(requests, hasLength(2));
      expect(clients.every((c) => c.closed), isTrue);
      // Losing credentials reports the missing work without deleting saved results.
      await File('${temp.path}/config').delete();
      final missing = await run(method: LanguageMethod.extensions);
      expect(
        missing.failures.keys,
        unorderedEquals(['.::framework', '.::tooling']),
      );
      final store = await SqliteClassificationStore.open(project.path);
      addTearDown(store.close);
      final manifest = (await store.readManifest())!;
      expect(
        (manifest['records'] as Map).keys,
        containsAll(['task:.::framework', 'task:.::tooling']),
      );
    },
  );

  test(
    'extension trees restore untouched branches and ignore content-only edits',
    () async {
      final a = Directory('${project.path}/docs/user')
        ..createSync(recursive: true);
      final b = Directory('${project.path}/docs/dev')
        ..createSync(recursive: true);
      File('${a.path}/README.md').writeAsStringSync('User docs');
      File('${b.path}/check.py').writeAsBytesSync([0, 255, 0]);
      final first = await run(method: LanguageMethod.extensions);
      expect(
        first.failures.keys,
        unorderedEquals(['.::framework', '.::tooling']),
      );
      expect(
        first.records['.::language']!.result.value!.labels.map((l) => l.value),
        ['dart', 'markdown', 'python'],
      );
      File('${a.path}/new.dart').writeAsStringSync('');
      final changed = await run(method: LanguageMethod.extensions);
      expect(
        changed.failures.keys,
        unorderedEquals(['.::framework', '.::tooling']),
      );
      expect(changed.executed, 1);
      expect(
        changed.records['docs/dev::language']!.id,
        first.records['docs/dev::language']!.id,
      );
      File(
        '${b.path}/check.py',
      ).writeAsStringSync('Entirely different contents');
      expect((await run(method: LanguageMethod.extensions)).executed, 0);
      expect(requests, isEmpty);
      expect(clients, isEmpty);
    },
  );

  test(
    'index sends configured JEV judgments, merges languages and restores without HTTP',
    () async {
      env['TYPESAFE_API_KEY'] = 'environment-key';
      await settings();
      final first = await run();
      expect(first.failures, isEmpty);
      expect(
        first.records['.::language']!.result.value!.labels.map((l) => l.value),
        ['dart', 'python'],
      );
      expect(requests, hasLength(1));
      final sent = requests.single;
      expect(sent.url.toString(), 'https://api.typesafe.ai/v1/systemone');
      expect(sent.headers['Authorization'], 'Bearer saved-key');
      final body = jsonDecode(sent.body) as Map;
      expect(body.keys, unorderedEquals(['model', 'state', 'questions']));
      expect(body['model'], 'jev-pinned');
      expect(sent.body, isNot(contains('SECRET FILE CONTENT')));
      expect(sent.body, isNot(contains('reasoning_effort')));
      expect(body['state']['inputs']['repository-relative filename'], [
        'main.dart',
        'script.py',
      ]);
      expect(clients.every((c) => c.closed), isTrue);
      expect((await run(mode: 'status')).failures, isEmpty);
      expect((await run()).executed, 0);
      expect(requests, hasLength(1));
      await settings(key: 'rotated-key');
      expect((await run(mode: 'refresh')).failures, isEmpty);
      expect(requests.last.headers['Authorization'], 'Bearer rotated-key');
      await settings(model: 'jev-new');
      expect((await run()).executed, 1);
      expect(jsonDecode(requests.last.body)['model'], 'jev-new');
    },
  );

  test(
    'missing key reports configuration error with no chat fallback or index writes',
    () async {
      await expectLater(
        run(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Typesafe'),
          ),
        ),
      );
      expect(requests, isEmpty);
      expect(
        await Directory('${project.path}/.tina/classifications').exists(),
        isFalse,
      );
      env['TYPESAFE_API_KEY'] = 'environment-key';
      expect((await run()).failures, isEmpty);
      expect(
        requests.single.headers['Authorization'],
        'Bearer environment-key',
      );
      expect(jsonDecode(requests.single.body)['model'], 'jev-latest');
    },
  );

  test(
    'HTTP authentication failures stay visible and never fall back to chat',
    () async {
      await settings();
      respond = (_) async => http.Response('denied', 401);
      final report = await run();
      expect(report.failures['.::language'], contains('authentication'));
      expect(report.records.keys, ['.::tooling']);
      expect(report.failures['.::framework'], contains('prerequisite'));
      expect(requests, hasLength(1));
      expect(clients.single.closed, isTrue);
    },
  );

  test(
    'cancel interrupts a stalled Typesafe request and closes its client',
    () async {
      await settings();
      final stop = Completer<void>();
      respond = (_) {
        stop.complete();
        return Completer<http.Response>().future;
      };
      final report = await run(
        cancel: stop.future,
      ).timeout(const Duration(seconds: 3));
      expect(report.cancelled, isTrue);
      expect(report.records, isEmpty);
      expect(clients.single.closed, isTrue);
    },
  );
}
