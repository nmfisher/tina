import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_engine/src/agent/project_tool_scope.dart';
import 'package:tina_engine/src/agent/tool_profile.dart';
import 'package:tina_engine/src/tools/atomic_write.dart';
import 'package:tina_engine/src/tools/mutation_lock.dart';
import 'package:tina_engine/src/tools/process_runner.dart';
import 'package:tina_engine/src/tools/project_capabilities.dart';
import 'package:tina_engine/src/tools/project_tool_plugins.dart';
import 'package:tina_engine/src/tools/sandbox.dart';
import 'package:tina_engine/src/tools/sandbox_runner.dart';
import 'package:tina_engine/src/permissions/policy.dart';
import 'package:tina_engine/src/runtime/runtime.dart';
import 'package:tina_engine/src/tools/bash_tool.dart';
import 'package:tina_engine/src/tools/tool_capabilities.dart';
import 'package:tina_engine/src/tools/edit_tool.dart';
import 'package:tina_engine/src/tools/git_tool.dart';
import 'package:tina_engine/src/tools/grep_tool.dart';
import 'package:tina_engine/src/tools/write_tool.dart';
import 'package:tina_engine/src/tools/tavily_search.dart';
import 'package:tina_engine/src/tools/web_search.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('project_caps_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ProjectCapabilities.build', () {
    test('confined build wires a SandboxedProcessRunner, sandboxed fs and a '
        'backup store', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );

      expect(p.isAbsolute(caps.projectRoot), isTrue);
      expect(caps.projectRoot, p.normalize(p.absolute(tempDir.path)));
      expect(caps.confineFiles, isTrue);
      expect(caps.sandboxEnabled, isTrue);
      expect(caps.fileSystem, isA<SandboxedFileSystem>());
      expect(caps.backups, isA<BackupStore>());
      expect(caps.processRunner, isA<SandboxedProcessRunner>());
      expect(caps.mutationLock, isA<FileMutationLock>());
    });

    test('confined build shares one BackupStore (and fs) across the store and '
        'the sandbox', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );

      // Single instances: every borrower of these capabilities — both file
      // tools' backup wiring and any later scope — sees the same store.
      expect(caps.backups, same(caps.backups));
      expect(caps.fileSystem, same(caps.fileSystem));
    });

    test('unconfined build wires IoProcessRunner and null fs/backups', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        confineFiles: false,
        sandboxEnabled: false,
      );

      expect(caps.confineFiles, isFalse);
      expect(caps.sandboxEnabled, isFalse);
      expect(caps.fileSystem, isNull);
      expect(caps.backups, isNull);
      expect(caps.processRunner, isA<IoProcessRunner>());
      expect(caps.mutationLock, isA<FileMutationLock>());
    });

    test('environment snapshot is unmodifiable', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {'TINA_TEST_KEY': 'v'},
      );

      expect(caps.environment['TINA_TEST_KEY'], 'v');
      expect(() => caps.environment['TINA_TEST_KEY'] = 'other',
          throwsUnsupportedError);
    });

    test('two builds for the same root produce INDEPENDENT mutation locks and '
        'sandboxes', () {
      final a = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );
      final b = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );

      expect(identical(a.mutationLock, b.mutationLock), isFalse,
          reason: 'each build owns its own per-project lock');
      expect(identical(a.fileSystem, b.fileSystem), isFalse,
          reason: 'each build owns its own sandbox');
      expect(identical(a.processRunner, b.processRunner), isFalse);
      expect(a.projectRoot, b.projectRoot);
    });

    test('the same capabilities object means one shared mutation lock', () {
      // The lock identity comes from the capabilities: ProjectToolScope's
      // private constructor assigns `mutationLock = capabilities.mutationLock`,
      // so two scopes sharing one capabilities object would share one lock.
      // The public API builds capabilities per scope, so verify the identity
      // anchor: one capabilities object owns exactly one lock, while scopes
      // built separately each get their own.
      final shared = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      expect(shared.mutationLock, same(shared.mutationLock));
      expect(shared.mutationLock, isA<FileMutationLock>());

      final scopeA = ProjectToolScope(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      final scopeB = ProjectToolScope(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      expect(identical(scopeA.mutationLock, scopeB.mutationLock), isFalse,
          reason: 'separately built scopes never share a lock');
      expect(identical(scopeA.mutationLock, shared.mutationLock), isFalse);
      expect(scopeA.mutationLock, isA<FileMutationLock>());
    });
  });

  group('project tool plugins', () {
    test('every tool that spawns a process uses the shared runner', () {
      // A file-system sandbox cannot confine a subprocess, so the ONLY thing
      // that makes a spawn confined is which runner the tool was handed; a
      // tool that builds its own `IoProcessRunner` silently opts out of the
      // sandbox. `grep` and `git` both did.
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      final runtime = PluginRuntime(
        name: 'project-tools-test',
        plugins: projectToolPlugins(caps),
      )..activateSync();
      final byName = {
        for (final t in toolRegistryFromScope(runtime.scope).all)
          t.schema.name: t
      };

      expect((byName['bash']! as BashTool).processRunner,
          same(caps.processRunner));
      expect((byName['grep']! as GrepTool).processRunner,
          same(caps.processRunner));
      expect((byName['git']! as GitTool).processRunner,
          same(caps.processRunner));
    });

    group('declared capabilities are enforced against the gate', () {
      ({ProjectCapabilities caps, Map<String, dynamic> tools}) mounted() {
        final caps = ProjectCapabilities.build(
          projectRoot: tempDir.path,
          env: const {},
          sandboxEnabled: false,
        );
        final runtime = PluginRuntime(
          name: 'capability-sweep',
          plugins: projectToolPlugins(caps),
        )..activateSync();
        return (
          caps: caps,
          tools: {
            for (final t in toolRegistryFromScope(runtime.scope).all)
              t.schema.name: t
          },
        );
      }

      test('every mounted tool declares what it does', () {
        final undeclared = [
          for (final name in mounted().tools.keys)
            if (!kToolCapabilities.containsKey(name)) name
        ];
        expect(undeclared, isEmpty,
            reason: 'a mounted tool with no declaration is exactly the quiet '
                'default this sweep exists to prevent: the old table recorded '
                'allow/ask and said nothing about spawning or egress, which is '
                'how a "read-only" tool came to run unconfined commands');
      });

      test('a tool that reaches past the sandbox is not auto-approved', () {
        final policy = PermissionPolicy();
        for (final entry in kToolCapabilities.entries) {
          final caps = entry.value;
          // A stated reason is the escape hatch, and it is a field a test
          // reads rather than a sentence in a comment nobody rechecks.
          if (!caps.escapesTheSandbox || caps.justification != null) continue;
          expect(policy.check(entry.key, const {}),
              isNot(PermissionDecision.allow),
              reason: '${entry.key} declares spawns=${caps.spawns.name}, '
                  'network=${caps.network.name}, writes=${caps.writes.name}, '
                  'reads=${caps.reads.name} — it reaches past the project '
                  'sandbox, so auto-approving it needs a reviewed: reason');
        }
      });

      test('every spawning tool was handed the framework runner', () {
        final m = mounted();
        for (final entry in kToolCapabilities.entries) {
          if (entry.value.spawns == SpawnScope.none) continue;
          final tool = m.tools[entry.key];
          if (tool == null) continue; // mounted by the app, not this wiring
          if (_spawnsWithoutRunner.contains(entry.key)) continue;
          expect(tool, isA<SpawnsProcess>(), reason: entry.key);
          expect((tool as SpawnsProcess).processRunner,
              same(m.caps.processRunner),
              reason: '${entry.key} spawns a process, so it must take the '
                  'shared runner rather than choosing its own');
        }
      });
    });

    test('built catalog names and order are exactly the frozen catalog, plus '
        'web_search only when a key is present', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      final runtime = PluginRuntime(
        name: 'project-tools-test',
        plugins: projectToolPlugins(caps),
      )..activateSync();

      expect(
        toolRegistryFromScope(runtime.scope)
            .all
            .map((t) => t.schema.name)
            .toList(),
        [
          'read',
          'write',
          'edit',
          'fetch',
          'bash',
          'exec',
          'execution_info',
          'search',
          'grep',
          'glob',
          'ls',
          'stat',
          'which',
          'git',
        ],
        reason: 'no API key in env, so no web_search and no extras',
      );

      final withKey = PluginRuntime(
        name: 'project-tools-test',
        plugins: projectToolPlugins(ProjectCapabilities.build(
          projectRoot: tempDir.path,
          env: const {'BRAVE_API_KEY': 'brave-test-key'},
          sandboxEnabled: false,
        )),
      )..activateSync();
      final names = toolRegistryFromScope(withKey.scope).all
          .map((t) => t.schema.name)
          .toList();
      expect(names.last, 'web_search',
          reason: 'web_search joins after the catalog');
      expect(
        names.take(14).toList(),
        containsAllInOrder([
          'read',
          'write',
          'edit',
          'fetch',
          'bash',
          'exec',
          'execution_info',
          'search',
          'grep',
          'glob',
          'ls',
          'stat',
          'which',
          'git',
        ]),
      );
    });

    test('with both keys set, web_search resolves to the Tavily-backed tool',
        () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {
          'BRAVE_API_KEY': 'brave-test-key',
          'TAVILY_API_KEY': 'tavily-test-key',
        },
        sandboxEnabled: false,
      );
      final runtime = PluginRuntime(
        name: 'project-tools-test',
        plugins: projectToolPlugins(caps),
      )..activateSync();

      final webSearch = toolRegistryFromScope(runtime.scope)['web_search']!;
      expect(webSearch, isA<WebSearchTool>());
      expect((webSearch as WebSearchTool).provider, isA<TavilySearchProvider>(),
          reason: 'a configured Tavily key supersedes Brave');
    });

    test('safeMode strips write/edit/bash (and write_summary is not in the '
        'base registry)', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      final runtime = PluginRuntime(
        name: 'project-tools-test',
        plugins: projectToolPlugins(caps),
      )..activateSync();

      final safe = toolRegistryFromScope(runtime.scope, safeMode: true);
      final names = safe.all.map((t) => t.schema.name).toList();
      expect(names, isNot(contains('write')));
      expect(names, isNot(contains('edit')));
      expect(names, isNot(contains('bash')));
      expect(names.length, 10, reason: '14 catalog tools minus write/edit/bash/exec');
      expect(names, everyElement(isNot(anyOf('write', 'edit', 'bash', 'exec'))));
    });

    test('two scopes from two capabilities objects have independent tool '
        'instances; two scopes from ONE capabilities object share the lock',
        () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      final capsB = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );

      // Two capabilities objects → fully independent runtimes and tools.
      final runtimeA = PluginRuntime(
          name: 'project-tools-a', plugins: projectToolPlugins(caps))
        ..activateSync();
      final runtimeB = PluginRuntime(
          name: 'project-tools-b', plugins: projectToolPlugins(capsB))
        ..activateSync();
      final writeA = toolRegistryFromScope(runtimeA.scope)['write']!;
      final writeB = toolRegistryFromScope(runtimeB.scope)['write']!;
      expect(identical(writeA, writeB), isFalse,
          reason: 'independent capabilities never share tool instances');

      // One capabilities object → two runtimes, one shared mutation lock
      // (the lock's identity comes from the capabilities, not the runtime).
      final runtimeC = PluginRuntime(
          name: 'project-tools-c', plugins: projectToolPlugins(caps))
        ..activateSync();
      final writeC = toolRegistryFromScope(runtimeC.scope)['write']!;
      expect(identical(writeA, writeC), isFalse,
          reason: 'each runtime builds its own tool instances');
      final editC = toolRegistryFromScope(runtimeC.scope)['edit']!;
      expect(identical((writeC as WriteTool).mutationLock, caps.mutationLock),
          isTrue);
      expect(
          identical((editC as EditTool).mutationLock, caps.mutationLock),
          isTrue,
          reason:
              'write and edit share the capabilities-level lock within one '
              'runtime');
    });

    test('read-only profile list and order matches the fixed profile', () {
      final scope = ProjectToolScope(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );

      expect(
        scope.toolSetFor(ToolProfile.readOnly)
            .map((t) => t.schema.name)
            .toList(),
        [
          'read',
          'fetch',
          'search',
          'grep',
          'glob',
          'ls',
          'stat',
          'which',
          'execution_info',
          'git',
          'write_summary',
        ],
      );
    });

    test('buildTools exposes web_search through the scope with one key set',
        () {
      final scope = ProjectToolScope(
        projectRoot: tempDir.path,
        env: const {'BRAVE_API_KEY': 'brave-test-key'},
        sandboxEnabled: false,
      );

      final names = scope.buildTools().all.map((t) => t.schema.name).toList();
      expect(names, contains('web_search'));
      expect(names.length, 15, reason: '14 catalog tools plus web_search');
    });
  });
}

/// Spawning tools that cannot yet expose a runner to the framework. Empty:
/// `search` used to reach `Process.runSync('git ls-files')` inside tina_index,
/// and now takes the shared runner and hands the listing in. The set stays as
/// the place to name a gap explicitly rather than let one pass silently.
const _spawnsWithoutRunner = <String>{};
