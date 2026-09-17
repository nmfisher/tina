import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_app/src/workflows/ask_user_tool.dart';
import 'package:tina_engine/tina_engine.dart';

class Source implements ProjectEvidenceSource {
  final List<ProjectEvidence> evidence;
  Source(this.evidence);
  @override
  Future<EvidenceScan> collect(
    String q,
    JudgmentCancellation c,
    void Function(String) progress,
  ) async => EvidenceScan(evidence, 3, ['fixture coverage']);
}

class Judge implements JudgmentService {
  final List<JudgmentRequest> requests = [];
  Future<JudgmentResult> Function(JudgmentRequest, JudgmentCancellation?)?
  handler;
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) {
    requests.add(request);
    return handler?.call(request, cancellation) ??
        Future.value(answer(request));
  }

  JudgmentResult answer(JudgmentRequest request, {int score = 4}) {
    final q = request.questions.values.single as ScoreQuestion;
    return JudgmentResult.fromJson({
      'model': 'jev-latest',
      'answers': {
        q.id: {
          'type': 'score',
          'score': score,
          'legend': {
            for (var i = 0; i < q.criteria.length; i++) '$i': q.criteria[i],
          },
          'probabilities': {
            for (var i = 0; i < q.criteria.length; i++)
              '$i': i == score ? 1 : 0,
          },
          'confidence': 0.9,
        },
      },
      'usage': {'input_tokens': 200, 'output_tokens': 20},
    }, request: request);
  }
}

ExplorationWorkflow workflow(
  ProjectEvidenceSource source,
  Judge judge, {
  int tokens = 100000,
  Duration timeout = const Duration(seconds: 3),
}) => ExplorationWorkflow(
  source: source,
  timeout: timeout,
  runner: JudgmentBatchRunner(
    service: judge,
    budget: JudgmentRequestBudget(),
    limits: JudgmentBatchLimits(
      maxChargedTokens: tokens,
      outputTokenAllowance: 100,
    ),
  ),
);
void main() {
  test('whole-workflow deadline settles stalled evidence collection', () async {
    final judge = Judge();
    final result = await workflow(
      _StalledSource(),
      judge,
      timeout: const Duration(milliseconds: 10),
    ).run('widget');
    expect(result.status, 'timeout');
    expect(judge.requests, isEmpty);
  });

  test('cancelling a stalled file enumeration kills the process', () async {
    final dir = await Directory.systemTemp.createTemp('tina-explore-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final processes = _StalledProcesses();
    final source = RepositoryEvidenceSource(
      root: dir.path,
      processes: processes,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        projectRoot: dir.path,
        tinaDir: Directory(p.join(dir.path, '.tina')),
      ),
    );
    final token = JudgmentCancellation();
    final pending = source.collect('widget', token, (_) {});
    await processes.started.future;
    token.cancel();
    await pending;
    expect(processes.process.killed, isTrue);
    expect(processes.args, contains('core.fsmonitor=false'));
    expect(processes.args, contains('--no-optional-locks'));
  });

  test(
    'typed findings preserve source locations, progress and measured usage',
    () async {
      final judge = Judge();
      final progress = <String>[];
      final result = await workflow(
        Source([
          const ProjectEvidence(
            'lib/auth.dart',
            12,
            'bool authenticate() {\n  return true;\n}',
            3,
          ),
        ]),
        judge,
      ).run('Where is authentication implemented?', onProgress: progress.add);
      expect(result.status, 'completed');
      expect(result.findings.single.toJson(), {
        'path': 'lib/auth.dart',
        'start_line': 12,
        'end_line': 14,
        'excerpt': 'bool authenticate() {\n  return true;\n}',
        'relevance': 1.0,
        'confidence': 0.9,
      });
      expect(result.inputTokens, 200);
      expect(result.outputTokens, 20);
      expect(result.gaps, contains('fixture coverage'));
      expect(progress.first, contains('collecting'));
      expect(progress.last, contains('completed'));
      expect(
        (judge.requests.single.state.value as Map)['source'],
        'lib/auth.dart',
      );
      expect(jsonEncode(result.toJson()), contains('"exhaustive":false'));
    },
  );
  test('no candidates incurs no API calls and never claims absence', () async {
    final judge = Judge();
    final result = await workflow(Source([]), judge).run('unicorn widget');
    expect(judge.requests, isEmpty);
    expect(result.findings, isEmpty);
    expect(result.gaps.join(), contains('not proof of absence'));
  });
  test(
    'ranking comes from judgments and filters irrelevant evidence',
    () async {
      final judge = Judge();
      judge.handler = (r, _) async => judge.answer(
        r,
        score: (r.state.value as Map)['source'] == 'a.dart' ? 1 : 4,
      );
      final result = await workflow(
        Source([
          const ProjectEvidence('a.dart', 1, 'mention', 99),
          const ProjectEvidence('b.dart', 7, 'implementation', 1),
        ]),
        judge,
      ).run('implementation location');
      expect(result.findings.single.path, 'b.dart');
    },
  );
  test('budget refusal is explicit and never calls provider', () async {
    final judge = Judge();
    final result = await workflow(
      Source([const ProjectEvidence('a.dart', 1, 'code', 1)]),
      judge,
      tokens: 1,
    ).run('find code');
    expect(result.status, 'failed');
    expect(judge.requests, isEmpty);
    expect(result.gaps.join(), contains('budgetExceeded'));
  });
  test('provider failure is typed and usage stays unknown', () async {
    final judge = Judge()
      ..handler = (r, c) async {
        throw const JudgmentException(JudgmentFailure.authentication);
      };
    final result = await workflow(
      Source([const ProjectEvidence('a.dart', 1, 'code', 1)]),
      judge,
    ).run('code');
    expect(result.status, 'failed');
    expect(result.inputTokens, isNull);
    expect(result.gaps.join(), contains('authentication'));
  });
  test(
    'tool propagates cancellation, refuses overlap and closes service',
    () async {
      final entered = Completer<void>();
      final judge = Judge();
      var cancelled = false;
      var closed = 0;
      judge.handler = (r, c) {
        entered.complete();
        final pending = Completer<JudgmentResult>();
        c!.listen(() {
          cancelled = true;
          pending.completeError(
            const JudgmentException(JudgmentFailure.cancelled),
          );
        });
        return pending.future;
      };
      final tool = ExploreProjectTool(
        open: () => ExplorationLease(
          workflow(
            Source([const ProjectEvidence('a.dart', 1, 'code', 1)]),
            judge,
          ),
          () => closed++,
        ),
      );
      final cancel = Completer<void>();
      final progress = <String>[];
      final pending = tool.execute(
        {'question': 'code'},
        cancelSignal: cancel.future,
        onOutput: (s, {bool stderr = false}) => progress.add(s),
      );
      await entered.future;
      expect((await tool.execute({'question': 'other'})).isError, isTrue);
      cancel.complete();
      final result = await pending;
      expect(jsonDecode(result.content)['status'], 'cancelled');
      expect(result.isError, isTrue);
      expect(cancelled, isTrue);
      expect(closed, 1);
      expect(progress.join(), contains('judging'));
    },
  );
  test(
    'missing key, invalid inputs and pre-cancellation avoid opening service',
    () async {
      var opened = 0;
      final tool = ExploreProjectTool(
        open: () {
          opened++;
          return null;
        },
      );
      expect((await tool.execute({'question': ''})).isError, isTrue);
      expect(
        (await tool.execute({'question': 'find', 'path': '/etc'})).isError,
        isTrue,
      );
      expect(opened, 0);
      expect(
        (await tool.execute({'question': 'find'})).content,
        contains('/settings'),
      );
      expect(opened, 1);
      await tool.execute({
        'question': 'find',
      }, cancelSignal: (Completer<void>()..complete()).future);
      expect(opened, 1);
    },
  );
  test(
    'restricted role and read-all allow exploration but preserve denial',
    () {
      final registry = orchestratorTools(
        AskUserTool(null),
        exploreProject: ExploreProjectTool(open: () => null),
      );
      expect(registry.schemas.map((s) => s.name), [
        'ask_user',
        'explore_project',
      ]);
      expect(registry.executionBlock('explore_project', {}), isNull);
      expect(registry.executionBlock('bash', {}), isNotNull);
      final policy = PermissionPolicy(mode: PermissionMode.readAll);
      expect(policy.executionBlock('explore_project', {}), isNull);
      expect(
        policy.check('explore_project', {'question': 'a'}),
        PermissionDecision.allow,
      );
      policy.remember('explore_project', '*', PermissionDecision.deny);
      expect(
        policy.check('explore_project', {'question': 'a'}),
        PermissionDecision.deny,
      );
    },
  );
  test(
    'real Git fixture honors ignores, bounds, symlinks and fresh edits',
    () async {
      final dir = await Directory.systemTemp.createTemp('tina-explore-test-');
      addTearDown(() => dir.delete(recursive: true));
      final root = Directory(p.join(dir.path, 'repo'))..createSync();
      final init = await Process.run('git', ['init', '-q', root.path]);
      expect(init.exitCode, 0);
      File(p.join(root.path, '.gitignore')).writeAsStringSync('ignored.dart\n');
      final source = File(p.join(root.path, 'auth.dart'))
        ..writeAsStringSync('bool authenticate() => true;\n');
      File(
        p.join(root.path, 'ignored.dart'),
      ).writeAsStringSync('authenticate ignored');
      File(p.join(root.path, '.env')).writeAsStringSync('authenticate SECRET');
      File(
        p.join(root.path, 'secrets.json'),
      ).writeAsStringSync('authenticate SECRET');
      File(p.join(root.path, 'binary.dart')).writeAsBytesSync([0, 1, 2]);
      final outside = File(p.join(dir.path, 'outside.dart'))
        ..writeAsStringSync('authenticate ESCAPED');
      if (!Platform.isWindows)
        await Link(p.join(root.path, 'linked.dart')).create(outside.path);
      final reader = RepositoryEvidenceSource(
        root: root.path,
        sandbox: SandboxedFileSystem(
          const IoFileSystem(),
          projectRoot: root.path,
          tinaDir: Directory(p.join(dir.path, 'tina')),
        ),
      );
      final first = await reader.collect(
        'authenticate',
        JudgmentCancellation(),
        (_) {},
      );
      expect(first.evidence.map((e) => e.path), ['auth.dart']);
      expect(first.evidence.single.startLine, 1);
      source.writeAsStringSync('bool authenticate() => false;\n');
      final second = await reader.collect(
        'authenticate',
        JudgmentCancellation(),
        (_) {},
      );
      expect(second.evidence.single.text, contains('false'));
      final bounded = RepositoryEvidenceSource(
        root: root.path,
        sandbox: reader.sandbox,
        maxFileBytes: 5,
      );
      expect(
        (await bounded.collect(
          'authenticate',
          JudgmentCancellation(),
          (_) {},
        )).evidence,
        isEmpty,
      );
    },
  );
}

class _StalledSource implements ProjectEvidenceSource {
  @override
  Future<EvidenceScan> collect(
    String q,
    JudgmentCancellation c,
    void Function(String) progress,
  ) => Completer<EvidenceScan>().future;
}

class _StalledProcess implements RunningProcess {
  bool killed = false;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  int get pid => -1;
  @override
  bool kill({bool force = false}) {
    killed = true;
    return true;
  }
}

class _StalledProcesses implements ProcessRunner {
  final started = Completer<void>();
  final process = _StalledProcess();
  List<String> args = [];
  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    expect(executable, 'git');
    args = arguments;
    started.complete();
    return process;
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => throw StateError('unexpected run');
}
