import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_app/src/workflows/ask_user_tool.dart';
import 'package:tina_engine/tina_engine.dart';

import 'helpers.dart';

void main() {
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
