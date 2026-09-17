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
  final List<List<String>> reads = [];
  final List<int?> allowances = [];
  Source(this.evidence);
  @override
  Future<ProjectTree> enumerate(
    JudgmentCancellation c,
    void Function(String) progress,
  ) async => ProjectTree(evidence.map((e) => e.path), []);
  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation c,
    void Function(String) progress, {
    int? maxBytes,
  }) async {
    reads.add(paths);
    allowances.add(maxBytes);
    final found = evidence.where((e) => paths.contains(e.path)).toList();
    final bytes = found.fold<int>(
      0,
      (sum, f) => sum + utf8.encode(f.text).length,
    );
    return maxBytes != null && bytes > maxBytes
        ? EvidenceScan(
            [],
            0,
            [],
            readFailures: {
              for (final path in paths) path: 'Read budget exceeded.',
            },
          )
        : EvidenceScan(found, found.length, [], bytesRead: bytes);
  }
}

class Judge implements JudgmentService {
  final List<JudgmentRequest> requests = [];
  Future<JudgmentResult> Function(JudgmentRequest, JudgmentCancellation?)?
  handler;
  Future<JudgmentResult> Function(JudgmentRequest, JudgmentCancellation?)?
  metadataHandler;
  List<JudgmentRequest> get contentRequests => requests
      .where((r) => (r.state.value as Map)['phase'] == 'content_check')
      .toList();
  List<JudgmentRequest> get metadataRequests => requests
      .where((r) => (r.state.value as Map)['phase'] == 'file_ranking')
      .toList();
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest r, {
    JudgmentCancellation? cancellation,
  }) {
    requests.add(r);
    if ((r.state.value as Map)['phase'] == 'file_ranking') {
      return metadataHandler?.call(r, cancellation) ??
          Future.value(answer(r, probability: 0.7));
    }
    return handler?.call(r, cancellation) ?? Future.value(answer(r));
  }

  JudgmentResult answer(JudgmentRequest r, {double probability = 0.9}) =>
      JudgmentResult.fromJson({
        'model': 'jev-latest',
        'answers': {
          for (final id in r.questions.keys)
            id: {'type': 'noul', 'noul': probability},
        },
        'usage': {'input_tokens': 200, 'output_tokens': 20},
      }, request: r);
}

Map<String, String> manifest(JudgmentRequest r) {
  final directories = (r.state.value as Map)['directories'] as Map;
  return {
    for (final d in directories.entries)
      for (final f in (d.value as Map).entries)
        f.key as String: d.key == '.'
            ? f.value as String
            : '${d.key}/${f.value}',
  };
}

JudgmentResult ranked(JudgmentRequest r, double Function(String) score) =>
    JudgmentResult.fromJson({
      'model': 'jev-latest',
      'answers': {
        for (final f in manifest(r).entries)
          f.key: {'type': 'noul', 'noul': score(f.value)},
      },
      'usage': {'input_tokens': 200, 'output_tokens': 20},
    }, request: r);

JudgmentBatchRunner batch(
  Judge judge, {
  int tokens = 100000,
  int concurrency = 2,
  JudgmentRequestBudget? budget,
}) => JudgmentBatchRunner(
  service: judge,
  budget: budget ?? JudgmentRequestBudget(),
  limits: JudgmentBatchLimits(
    concurrency: concurrency,
    maxRequests: 5000,
    maxChargedTokens: tokens,
    outputTokenAllowance: 100,
  ),
);
ExplorationWorkflow workflow(
  ProjectEvidenceSource source,
  Judge judge, {
  int tokens = 100000,
  Duration timeout = const Duration(seconds: 3),
}) => ExplorationWorkflow(
  source: source,
  timeout: timeout,
  runner: batch(judge, tokens: tokens),
);

void main() {
  test(
    'auto handoff threshold is configurable without pruning verification',
    () async {
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      final judge = Judge()
        ..metadataHandler = (r, _) async => ranked(r, (_) => 0.85);
      final result = await ExplorationWorkflow(
        source: source,
        runner: batch(judge),
        selectionThreshold: 0.8,
      ).run('code');
      expect(result.stopReason, 'candidate_handoff');
      expect(judge.contentRequests, isEmpty);
    },
  );

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
    final pending = source.enumerate(token, (_) {});
    await processes.started.future;
    token.cancel();
    await pending;
    expect(processes.process.killed, isTrue);
    expect(processes.args, contains('core.fsmonitor=false'));
    expect(processes.args, contains('--no-optional-locks'));
  });

  test(
    'one compact manifest includes deeply nested files without directory gates',
    () async {
      final source = Source([
        const ProjectEvidence('docs/guide.md', 'docs'),
        const ProjectEvidence(
          'packages/engine/lib/src/agent/cancel.dart',
          'stopTool();',
        ),
      ]);
      final judge = Judge()
        ..metadataHandler = (r, _) async {
          expect(source.reads, isEmpty);
          expect((r.state.value as Map)['manifest_scope'], 'whole_project');
          expect(
            manifest(r).values,
            contains('packages/engine/lib/src/agent/cancel.dart'),
          );
          return ranked(r, (path) => path.endsWith('cancel.dart') ? 0.95 : 0.1);
        };
      final result = await workflow(source, judge).run('cancellation');
      expect(judge.metadataRequests, hasLength(1));
      expect(judge.contentRequests, isEmpty);
      expect(source.reads.single, [
        'packages/engine/lib/src/agent/cancel.dart',
      ]);
      expect(result.stopReason, 'candidate_handoff');
      expect(result.files.single.unverifiedExcerpt!.text, 'stopTool();');
      expect(result.files.single.regions, isEmpty);
      expect(result.firstEvidenceMs, isNotNull);
    },
  );

  test(
    'manifest pages fit context and run concurrently with stable IDs',
    () async {
      final budget = JudgmentRequestBudget(
        maxInputTokens: 1800,
        overheadTokens: 100,
      );
      var active = 0;
      var peak = 0;
      final judge = Judge();
      judge.metadataHandler = (r, _) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
        return judge.answer(r);
      };
      final tree = ProjectTree(
        List.generate(80, (i) => 'packages/p$i/lib/src/file.dart'),
        [],
      );
      final result = await RepositoryRanker(
        batch(judge, budget: budget),
      ).run(tree, 'cancellation', JudgmentCancellation(), (_) {});
      expect(peak, 2);
      expect(result.complete, isTrue);
      expect(result.files, hasLength(80));
      final ids = <String>{};
      for (final r in judge.requests) {
        expect(budget.check(r), lessThanOrEqualTo(1800));
        expect(ids.intersection(manifest(r).keys.toSet()), isEmpty);
        ids.addAll(manifest(r).keys);
      }
      expect(ids, hasLength(80));
    },
  );

  test('rank mode reads no bodies and bounds the main-agent handoff', () async {
    final source = Source(
      List.generate(50, (i) => ProjectEvidence('f$i.dart', 'code')),
    );
    final result = await workflow(
      source,
      Judge(),
    ).run('code', mode: ExplorationMode.rank);
    expect(source.reads, isEmpty);
    expect(result.contentRequests, 0);
    expect(result.toJson()['candidates'], hasLength(8));
    expect(result.ranking.files, hasLength(50));
  });

  test('first useful wave stops reading the remaining repository', () async {
    final source = Source(
      List.generate(
        80,
        (i) => ProjectEvidence('f${i.toString().padLeft(2, '0')}.dart', 'code'),
      ),
    );
    final judge = Judge();
    final result = await workflow(
      source,
      judge,
    ).run('code', mode: ExplorationMode.verify);
    expect(result.stopReason, 'enough_evidence');
    expect(source.reads, hasLength(2));
    expect(judge.contentRequests, hasLength(2));
    expect(result.files.first.regions.single.excerpt!.text, 'code');
    expect((result.toJson()['coverage'] as Map)['files_deferred'], 78);
  });

  test(
    'inconclusive waves expand to low filename scores rather than pruning',
    () async {
      final source = Source(
        List.generate(5, (i) => ProjectEvidence('f$i.dart', 'code')),
      );
      final judge = Judge()
        ..metadataHandler = (r, _) async =>
            ranked(r, (path) => path == 'f4.dart' ? 0.1 : 0.7);
      judge.handler = (r, _) async => judge.answer(
        r,
        probability: (r.state.value as Map)['path'] == 'f4.dart' ? 0.95 : 0.1,
      );
      final result = await workflow(source, judge).run('code');
      expect(result.stopReason, 'enough_evidence');
      expect(source.reads, hasLength(5));
      expect(result.files.last.regions.single.excerpt, isNotNull);
    },
  );

  test(
    'large files split into concurrent requests and return a matching region',
    () async {
      final budget = JudgmentRequestBudget(
        maxInputTokens: 1800,
        overheadTokens: 100,
      );
      final text = 'x' * 1700 + '\nCANCEL_HERE();\n';
      final source = Source([ProjectEvidence('big.dart', text)]);
      final judge = Judge();
      var active = 0;
      var peak = 0;
      judge.handler = (r, _) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
        return judge.answer(
          r,
          probability:
              ((r.state.value as Map)['content'] as String).contains(
                'CANCEL_HERE',
              )
              ? 0.95
              : 0.1,
        );
      };
      final result = await ExplorationWorkflow(
        source: source,
        runner: batch(judge, budget: budget),
      ).run('cancellation', mode: ExplorationMode.verify);
      expect(judge.contentRequests, hasLength(2));
      expect(peak, 2);
      expect(result.files.single.chunksTotal, 2);
      final region = result.files.single.regions.singleWhere(
        (r) => r.excerpt != null,
      );
      expect(region.excerpt!.text, contains('CANCEL_HERE'));
      expect(region.endLine, 2);
      expect(result.stopReason, 'enough_evidence');
    },
  );

  test(
    'chunking covers Unicode, boundaries and long lines without losing text',
    () {
      final budget = JudgmentRequestBudget(
        maxInputTokens: 1700,
        overheadTokens: 100,
      );
      for (final text in [
        '',
        '👋' * 700,
        'void f() {\n  stop(); // 汉字👋\n}\n\n' * 100,
      ]) {
        final chunks = FileChunker(
          budget,
        ).split(ProjectEvidence('a.dart', text), 'cancel');
        final runes = text.runes.toList();
        var covered = 0;
        for (final c in chunks) {
          expect(c.startScalar, lessThanOrEqualTo(covered));
          expect(
            c.text,
            String.fromCharCodes(runes.sublist(c.startScalar, c.endScalar)),
          );
          expect(
            c.startLine,
            1 + runes.take(c.startScalar).where((r) => r == 10).length,
          );
          expect(budget.check(c.request), lessThanOrEqualTo(1700));
          covered = c.endScalar;
        }
        expect(covered, runes.length);
      }
    },
  );

  test('run read budget is shared across successive content waves', () async {
    final source = Source(
      List.generate(5, (i) => ProjectEvidence('f$i.dart', 'x' * 10)),
    );
    final judge = Judge();
    judge.handler = (r, _) async => judge.answer(r, probability: 0.1);
    final result = await ExplorationWorkflow(
      source: source,
      runner: batch(judge),
      maxReadBytes: 20,
    ).run('code', mode: ExplorationMode.verify);
    expect(source.allowances, [20, 10]);
    expect(result.stopReason, 'read_budget');
    expect(result.status, 'partial');
  });

  test(
    'content budget refusal preserves ranked paths and does not send bodies',
    () async {
      final judge = Judge();
      final result = await workflow(
        Source([const ProjectEvidence('a.dart', 'code')]),
        judge,
        tokens: 1,
      ).run('code', mode: ExplorationMode.verify);
      expect(result.status, 'partial');
      expect(judge.contentRequests, isEmpty);
      expect(
        result.files.single.regions.single.failure,
        JudgmentFailure.budgetExceeded,
      );
    },
  );

  test('cancellation during ranking starts no file reads', () async {
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    final entered = Completer<void>();
    final stop = JudgmentCancellation();
    final judge = Judge()
      ..metadataHandler = (r, c) {
        entered.complete();
        final pending = Completer<JudgmentResult>();
        c!.listen(
          () => pending.completeError(
            const JudgmentException(JudgmentFailure.cancelled),
          ),
        );
        return pending.future;
      };
    final pending = workflow(source, judge).run('code', cancellation: stop);
    await entered.future;
    stop.cancel();
    expect((await pending).status, 'cancelled');
    expect(source.reads, isEmpty);
  });

  test('whole-workflow deadline settles a stalled evidence adapter', () async {
    final result = await workflow(
      _StalledSource(),
      Judge(),
      timeout: const Duration(milliseconds: 10),
    ).run('code');
    expect(result.status, 'timeout');
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
          workflow(Source([const ProjectEvidence('a.dart', 'code')]), judge),
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
      expect(progress.join(), contains('checking'));
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
      final first = await readAll(reader);
      expect(first.evidence.map((e) => e.path), ['auth.dart']);

      source.writeAsStringSync('bool authenticate() => false;\n');
      File(p.join(root.path, 'z.dart')).writeAsStringSync('return 42;');
      File(
        p.join(root.path, 'cancel_token.dart'),
      ).writeAsStringSync('stopWork();');
      final second = await readAll(reader);
      expect(second.evidence.map((e) => e.path), [
        'auth.dart',
        'cancel_token.dart',
        'z.dart',
      ]);
      expect(second.evidence.first.text, 'bool authenticate() => false;\n');
      expect(second.evidence.last.text, 'return 42;');
      File(p.join(root.path, 'large.dart')).writeAsStringSync('x' * 150000);
      final large = await reader.read(
        ['large.dart'],
        JudgmentCancellation(),
        (_) {},
      );
      expect(large.evidence.single.text.length, 150000);
      final denied = await reader.read(
        ['large.dart'],
        JudgmentCancellation(),
        (_) {},
        maxBytes: 100,
      );
      expect(denied.evidence, isEmpty);
      expect(denied.readFailures['large.dart'], contains('read budget'));
      final bounded = RepositoryEvidenceSource(
        root: root.path,
        sandbox: reader.sandbox,
        maxFileBytes: 5,
      );
      expect((await readAll(bounded)).evidence, isEmpty);
    },
  );
}

Future<EvidenceScan> readAll(RepositoryEvidenceSource source) async {
  final token = JudgmentCancellation();
  final tree = await source.enumerate(token, (_) {});
  return source.read(tree.paths, token, (_) {});
}

class _StalledSource implements ProjectEvidenceSource {
  @override
  Future<ProjectTree> enumerate(
    JudgmentCancellation c,
    void Function(String) progress,
  ) => Completer<ProjectTree>().future;
  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation c,
    void Function(String) progress, {
    int? maxBytes,
  }) => throw StateError('Unexpected read');
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
