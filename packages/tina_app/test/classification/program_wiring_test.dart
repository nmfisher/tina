import 'dart:io';

import 'package:tina_app/classification.dart' show ProjectClassificationReport;
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/memory_session_store.dart';

class Service implements JudgmentService {
  int calls = 0;
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    calls++;
    return JudgmentResult.fromJson({
      'model': 'jev-test',
      'usage': {'input_tokens': 100, 'output_tokens': 50},
      'answers': {
        for (final key in request.questions.keys)
          key: {'type': 'noul', 'noul': 0.5},
      },
    }, request: request);
  }
}

/// `/index` program wiring (proposal: load workspace/global/built-in program,
/// surface invalid files instead of masking them, report stage walks as
/// progress). Global programs are disabled per test — hermetic by default.
void main() {
  final service = Service();

  Future<Directory> workspace() async {
    final project = await Directory.systemTemp.createTemp(
      'classification-program-wiring-',
    );
    addTearDown(() => project.delete(recursive: true));
    await Process.run('git', ['init', '-q', project.path]);
    await File('${project.path}/README.md').writeAsString('Example');
    return project;
  }

  Future<AppComposition> build(Directory project) {
    final registry = ProviderRegistry(env: const {})
      ..register(
        ProviderDescriptor(
          id: 'test',
          name: 'Test',
          authSources: const [],
          defaultBaseUrl: 'https://example.test',
          builder: (_) =>
              throw StateError('Index must never construct a chat provider'),
        ),
      );
    return buildAppComposition(
      config: RuntimeConfig(
        provider: 'test',
        model: 'slow-chat-model',
        permissionMode: PermissionMode.readAll,
      ),
      registry: registry,
      store: MemorySessionStore(),
      workspaceRoot: project.path,
      loadWorkspaceContext: false,
    );
  }

  Future<ProjectClassificationReport> run(
    AppComposition app, {
    void Function(String)? onProgress,
  }) =>
      runProjectClassification(
        app,
        method: LanguageMethod.jev,
        judgments: service,
        requestBudget: JudgmentRequestBudget(model: 'jev-test'),
        serviceIdentity: 'test-judgments',
        globalWorkflowsDir: null,
        onProgress: onProgress,
      );

  test(
    'a workspace program replaces the built-in: details never runs',
    () async {
      final project = await workspace();
      await Directory('${project.path}/.tina/programs').create(
        recursive: true,
      );
      await File('${project.path}/.tina/programs/index.dot').writeAsString('''
digraph index {
  graph [goal="Classify the workspace index"];
  start [shape=Mdiamond];
  language [type="classify"];
  exit [shape=Msquare];
  start -> language;
  language -> exit;
}
''');
      final app = await build(project);
      addTearDown(app.dispose);

      final progress = <String>[];
      final report = await run(app, onProgress: progress.add);

      expect(report.failures, isEmpty);
      expect(report.cancelled, isFalse);
      expect(
        report.records.keys.any((k) => k.endsWith('::language')),
        isTrue,
        reason: 'the program still runs the language stage',
      );
      expect(
        report.records.keys.any(
          (k) => k.endsWith('::framework') || k.endsWith('::tooling'),
        ),
        isFalse,
        reason: 'the edited program has no route to details',
      );
      expect(
        progress,
        contains('Program index: stage language'),
        reason: 'PipelineEvents surface as progress lines',
      );
    },
  );

  test(
    'an invalid program file fails fast with its diagnostics',
    () async {
      final project = await workspace();
      await Directory('${project.path}/.tina/programs').create(
        recursive: true,
      );
      await File('${project.path}/.tina/programs/index.dot').writeAsString(
        'certainly not a digraph {',
      );
      final app = await build(project);
      addTearDown(app.dispose);
      final callsBefore = service.calls;

      final report = await run(app);

      expect(report.records, isEmpty);
      expect(report.executed, 0);
      expect(service.calls, callsBefore, reason: 'no classifier ran');
      expect(report.failures['program'], contains('invalid classify program'));
      expect(report.failures['program'], contains('index.dot'));
    },
  );
}
