// Speculative read-only execution: the canonical call key, the bounded
// cache, the wrapped executor seam, the prefetch runner's invalidation
// discipline, and the ToolsPlugin wiring end to end (over a temp
// workspace — the tools themselves need a real directory).
//
// Run: dart test test/speculative_cache_test.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart'
    show CancelToken, ContextToolExecutor, ToolExecutionContext;
import 'package:tina_tools/tina_tools.dart';

void main() {
  group('SpeculativeCache keys', () {
    late SpeculativeCache cache;
    setUp(() => cache = SpeculativeCache(defaults: const {
          'ls': {'maxResults': 200, 'all': false},
        }));

    test('argument order does not change identity', () {
      final a = cache.keyOf('ls', {'path': 'lib', 'all': true});
      final b = cache.keyOf('ls', {'all': true, 'path': 'lib'});
      expect(a, b);
    });

    test('path spellings collapse to one form', () {
      expect(cache.keyOf('ls', {'path': './lib/'}),
          cache.keyOf('ls', {'path': 'lib'}));
      expect(cache.keyOf('ls', {'path': 'a//b'}),
          cache.keyOf('ls', {'path': 'a/b'}));
    });

    test('omitted defaults collide with explicit defaults', () {
      expect(cache.keyOf('ls', {'path': 'x'}),
          cache.keyOf('ls', {'path': 'x', 'maxResults': 200, 'all': false}));
      // A different explicit value is a different call.
      expect(cache.keyOf('ls', {'path': 'x'}),
          isNot(cache.keyOf('ls', {'path': 'x', 'all': true})));
    });

    test('different tools never share a key', () {
      expect(cache.keyOf('ls', {'path': 'x'}),
          isNot(cache.keyOf('glob', {'path': 'x'})));
    });

    test('non-JSON-safe input yields null (never cached)', () {
      expect(cache.keyOf('ls', {'path': Object()}), isNull);
    });
    test('glob patterns stay literal; empty and current-directory paths differ',
        () {
      expect(cache.keyOf('glob', {'pattern': '*.dart'}),
          isNot(cache.keyOf('glob', {'pattern': './*.dart'})));
      expect(cache.keyOf('read', {'filePath': ''}),
          isNot(cache.keyOf('read', {'filePath': './'})));
      expect(
          cache.keyOf('ls', {'path': './'}), cache.keyOf('ls', {'path': '.'}));
      expect(cache.keyOf('read', {'limit': double.nan}), isNull);
    });
  });

  group('SpeculativeCache storage', () {
    test('stores, hits, and counts', () {
      final cache = SpeculativeCache();
      const result = ToolResult('entry d 100 a.txt');
      cache.put('ls', {'path': 'lib'}, result);
      expect(cache.get('ls', {'path': 'lib'}), same(result));
      expect(cache.get('ls', {'path': './lib'}), same(result));
      final s = cache.stats;
      expect(s.hits, 2);
      expect(s.entries, 1);
    });

    test('error results are cached like successes', () {
      final cache = SpeculativeCache();
      const error = ToolResult('path does not exist: x', isError: true);
      cache.put('stat', {'path': 'x'}, error);
      expect(cache.get('stat', {'path': 'x'})?.isError, isTrue);
    });

    test('oversized results are never stored', () {
      final cache = SpeculativeCache(maxResultLength: 16);
      cache.put('read', {'filePath': 'big'}, ToolResult('x' * 128));
      expect(cache.peek('read', {'filePath': 'big'}), isNull);
      expect(cache.stats.entries, 0);
    });

    test('LRU eviction beyond maxEntries', () {
      final cache = SpeculativeCache(maxEntries: 2);
      cache.put('ls', {'path': 'a'}, const ToolResult('a'));
      cache.put('ls', {'path': 'b'}, const ToolResult('b'));
      cache.get('ls', {'path': 'a'}); // refresh a
      cache.put('ls', {'path': 'c'}, const ToolResult('c')); // evicts b
      expect(cache.peek('ls', {'path': 'b'}), isNull);
      expect(cache.peek('ls', {'path': 'a'}), isNotNull);
      expect(cache.peek('ls', {'path': 'c'}), isNotNull);
      expect(cache.stats.evictions, 1);
    });

    test('clear bumps generation and drops entries', () {
      final cache = SpeculativeCache();
      cache.put('ls', {'path': 'a'}, const ToolResult('a'));
      final before = cache.generation;
      cache.clear();
      expect(cache.peek('ls', {'path': 'a'}), isNull);
      expect(cache.generation, before + 1);
    });
  });

  group('cache.wrap (the executor seam)', () {
    test('a read that finishes after clear cannot repopulate the cache',
        () async {
      final cache = SpeculativeCache();
      final started = Completer<void>();
      final result = Completer<ToolResult>();
      final wrapped = cache.wrap('read', (_) {
        started.complete();
        return result.future;
      });
      final running = wrapped({'filePath': 'a'});
      await started.future;
      cache.clear();
      result.complete(const ToolResult('old'));
      await running;
      expect(cache.stats.entries, 0);
    });
    test('hit returns instantly without running the inner executor', () async {
      final cache = SpeculativeCache();
      cache.put('ls', {'path': 'lib'}, const ToolResult('cached listing'));
      var ran = 0;
      final wrapped = cache.wrap('ls', (_) async => ToolResult('ran $ran'));
      final out = await wrapped({'path': 'lib'});
      expect(out.content, 'cached listing');
      expect(ran, 0);
    });

    test('miss runs the inner executor and stores for next time', () async {
      final cache = SpeculativeCache();
      var ran = 0;
      final wrapped = cache.wrap('stat', (_) async {
        ran++;
        return ToolResult('ran=$ran');
      });
      expect((await wrapped({'path': 'p'})).content, 'ran=1');
      expect((await wrapped({'path': 'p'})).content, 'ran=1');
      expect(ran, 1);
    });
  });

  group('SpeculativePrefetch', () {
    test('cancellation during a read drops its result and stops the batch',
        () async {
      final cache = SpeculativeCache();
      final token = CancelToken();
      final started = Completer<void>();
      final result = Completer<ToolResult>();
      var ran = 0;
      final prefetch = SpeculativePrefetch(cache, {
        'read': (_) {
          ran++;
          started.complete();
          return result.future;
        }
      });
      final running = prefetch.submit([
        ('read', {'filePath': 'a'}),
        ('read', {'filePath': 'b'}),
      ], untilCancelled: token.whenCancelled);
      await started.future;
      token.cancel('cancelled while reading');
      result.complete(const ToolResult('old'));
      await running;
      expect(cache.stats.entries, 0);
      expect(ran, 1);
    });
    test('mutation blocks prediction storage and a new batch during mutation',
        () async {
      final cache = SpeculativeCache();
      var ran = 0;
      final prefetch = SpeculativePrefetch(cache, {
        'ls': (_) async {
          ran++;
          return const ToolResult('snapshot');
        }
      });
      cache.beginMutation();
      cache.put('ls', {}, const ToolResult('old'));
      await prefetch.submit([('ls', <String, Object?>{})]);
      expect(ran, 0);
      expect(cache.stats.entries, 0);
      cache.endMutation();
      await prefetch.submit([('ls', <String, Object?>{})]);
      expect(ran, 1);
      expect(cache.stats.entries, 1);
    });
    test('fills the cache; consumer gets a hit', () async {
      final cache = SpeculativeCache();
      final prefetch = SpeculativePrefetch(cache, {
        'ls': (_) async => const ToolResult('listing'),
      });
      await prefetch.submit([
        ('ls', {'path': 'lib'}),
      ]);
      expect(cache.get('ls', {'path': 'lib'})?.content, 'listing');
      expect(cache.stats.prefetched, 1);
      expect(cache.stats.hits, 1);
      expect(cache.stats.misses, 0);
    });

    test('skips mutating tools even if a caller submits them', () async {
      final cache = SpeculativeCache();
      var ran = 0;
      final prefetch = SpeculativePrefetch(cache, {
        'write': (_) async {
          ran++;
          return const ToolResult('wrote');
        },
      });
      await prefetch.submit([
        ('write', {'path': 'x'}),
      ]);
      expect(ran, 0);
      expect(cache.peek('write', {'path': 'x'}), isNull);
    });

    test('already-cached calls are skipped without re-execution', () async {
      final cache = SpeculativeCache();
      var ran = 0;
      final prefetch = SpeculativePrefetch(cache, {
        'ls': (_) async {
          ran++;
          return const ToolResult('x');
        },
      });
      cache.put('ls', {'path': 'a'}, const ToolResult('cached'));
      await prefetch.submit([
        ('ls', {'path': 'a'}),
        ('ls', {'path': 'b'}),
      ]);
      expect(ran, 1);
    });

    test('a clear mid-batch drops in-flight results', () async {
      final cache = SpeculativeCache();
      final gate = Completer<void>();
      final prefetch = SpeculativePrefetch(cache, {
        'ls': (_) async {
          await gate.future;
          return const ToolResult('late');
        },
      });
      final running = prefetch.submit([
        ('ls', {'path': 'x'}),
      ]);
      await Future<void>.delayed(Duration.zero);
      cache.clear(); // a real mutation lands while the prefetch runs
      gate.complete();
      await running;
      expect(cache.peek('ls', {'path': 'x'}), isNull,
          reason: 'stale state must not land after invalidation');
      expect(cache.stats.prefetched, 0);
    });

    test('a superseding batch stops the earlier one', () async {
      final cache = SpeculativeCache();
      final firstGate = Completer<void>();
      var secondRan = 0;
      final prefetch = SpeculativePrefetch(cache, {
        'ls': (input) async {
          if (input['path'] == 'two') {
            secondRan++;
            return const ToolResult('second');
          }
          await firstGate.future;
          return const ToolResult('first');
        },
      });
      final first = prefetch.submit([
        ('ls', {'path': 'one'}),
      ]);
      await Future<void>.delayed(Duration.zero);
      final second = prefetch.submit([
        ('ls', {'path': 'two'}),
      ]);
      firstGate.complete();
      await first;
      await second;
      expect(cache.peek('ls', {'path': 'one'}), isNull,
          reason: 'the superseded batch must not store');
      expect(cache.peek('ls', {'path': 'two'})?.content, 'second');
      expect(secondRan, 1);
    });

    test('stops between items when the turn token fires', () async {
      final cache = SpeculativeCache();
      var ran = 0;
      final token = CancelToken();
      final prefetch = SpeculativePrefetch(cache, {
        'ls': (_) async {
          ran++;
          return const ToolResult('x');
        },
      });
      token.cancel('turn over');
      await prefetch.submit([
        ('ls', {'path': 'a'}),
        ('ls', {'path': 'b'}),
      ], untilCancelled: token.whenCancelled);
      expect(ran, 0);
    });
  });

  group('ToolsPlugin speculative wiring', () {
    late Directory ws;
    late ToolsPlugin plugin;
    late _LoopCapture loop;
    late Map<String, ContextToolExecutor> exec;

    // Only the process tools read the context; they are not under test
    // here, so a plain non-cancelled context is enough for every call.
    final context = ToolExecutionContext(
      isCancelled: () => false,
      whenCancelled: Completer<void>().future,
      report: (_, {isError = false}) {},
    );

    Future<ToolResult> run(String tool, Map<String, Object?> input) =>
        exec[tool]!(input, context);

    setUp(() {
      ws = Directory.systemTemp.createTempSync('tina_spec_ws_');
      addTearDown(() => ws.deleteSync(recursive: true));
      Directory('${ws.path}/lib').createSync();
      File('${ws.path}/lib/a.dart').writeAsStringSync('void main() {}\n');
      plugin = ToolsPlugin(
        workspaceRoot: ws.path,
        tinaDir: Directory('${ws.path}/.tina'),
        osSandbox: false,
        enableSpeculative: true,
      );
      addTearDown(plugin.closeSession);
      loop = _LoopCapture();
      plugin.registerExecutors(loop.register);
      exec = loop.executors;
    });

    test('predicted canonical hit is consumed once; ordinary reads stay fresh',
        () async {
      await plugin.speculativePrefetch.submit([
        ('ls', {'path': 'lib'})
      ]);
      final first = await run('ls', {'path': 'lib'});
      expect(first.isError, false);
      expect(first.content, contains('a.dart'));
      File('${ws.path}/lib/new.dart').writeAsStringSync('new');
      final second = await run('ls', {'path': './lib/'});
      expect(second.content, contains('new.dart'));
      expect(plugin.speculativeStats.hits, 1);
      expect(plugin.speculativeStats.misses, 1);
      expect(plugin.speculativeStats.entries, 0);
    });

    test('a mutating executor clears the cache even on failure', () async {
      await plugin.speculativePrefetch.submit([
        ('ls', {'path': 'lib'})
      ]);
      expect(plugin.speculativeStats.entries, 1);
      await run('write', {'filePath': 'lib/new.txt', 'content': 'hi'});
      expect(plugin.speculativeStats.entries, 0,
          reason: 'a write invalidates read-only results');
      await plugin.speculativePrefetch.submit([
        ('ls', {'path': 'lib'})
      ]);
      await run('bash', {'command': 'false'});
      expect(plugin.speculativeStats.entries, 0,
          reason: 'a failed bash may still have changed the world');
    });

    test('cached reads obey a changed sandbox boundary', () async {
      await plugin.speculativePrefetch.submit([
        ('read', {'filePath': 'lib/a.dart'})
      ]);
      expect(plugin.speculativeStats.entries, 1);
      plugin.sandbox.reTina(Directory('${ws.path}/lib'));
      final result = await run('read', {'filePath': 'lib/a.dart'});
      expect(result.isError, isTrue);
      expect(result.content, contains('Tina data tree is blocked'));
      expect(plugin.speculativeStats.hits, 0);
    });

    test('predictions submitted during an actual write cannot survive it',
        () async {
      final paused = _PausedFileSystem();
      plugin.sandbox.reinner(paused);
      plugin.mode = PermissionMode.allowEdits;
      final writing =
          run('write', {'filePath': 'lib/a.dart', 'content': 'updated'});
      await paused.started.future;
      await plugin.speculativePrefetch.submit([
        ('read', {'filePath': 'lib/a.dart'})
      ]);
      expect(plugin.speculativeStats.entries, 0);
      paused.release.complete();
      expect((await writing).isError, isFalse);
      expect(plugin.speculativeStats.entries, 0);
      await plugin.speculativePrefetch.submit([
        ('read', {'filePath': 'lib/a.dart'})
      ]);
      expect((await run('read', {'filePath': 'lib/a.dart'})).content,
          contains('updated'));
    });

    test('closing an enabled plugin prevents later speculative reads',
        () async {
      plugin.closeSession();
      await plugin.speculativePrefetch.submit([
        ('read', {'filePath': 'lib/a.dart'})
      ]);
      expect(plugin.speculativeStats.prefetched, 0);
    });

    test('distinct glob patterns produce their own results', () async {
      await plugin.speculativePrefetch.submit([
        ('glob', {'pattern': '*.dart', 'path': 'lib'})
      ]);
      final result = await run('glob', {'pattern': './*.dart', 'path': 'lib'});
      expect(result.content, '(no matches)');
    });

    test(
        'speculation is disabled by default, including direct prefetch submissions',
        () async {
      final ordinary = ToolsPlugin(
          workspaceRoot: ws.path,
          tinaDir: Directory('${ws.path}/.tina'),
          osSandbox: false);
      addTearDown(ordinary.closeSession);
      final dispatch = _LoopCapture();
      ordinary.registerExecutors(dispatch.register);
      await ordinary.speculativePrefetch.submit([
        ('read', {'filePath': 'lib/a.dart'})
      ]);
      expect(ordinary.speculativeStats.entries, 0);
      await dispatch.executors['read']!({'filePath': 'lib/a.dart'}, context);
      File('${ws.path}/lib/a.dart').writeAsStringSync('external change');
      final result = await dispatch.executors['read']!(
          {'filePath': 'lib/a.dart'}, context);
      expect(result.content, contains('external change'));
      expect(ordinary.speculativeStats.stored, 0);
    });

    test('prefetch through the plugin seam serves the real executor', () async {
      await plugin.speculativePrefetch.submit([
        ('ls', {'path': 'lib'}),
      ]);
      final out = await run('ls', {'path': 'lib'});
      expect(out.content, contains('a.dart'));
      expect(plugin.speculativeStats.hits, 1);
      expect(plugin.speculativeStats.misses, 0);
    });
  });
}

/// Captures the executors the plugin registers, standing in for the loop.
/// [ToolsPlugin.registerExecutors] takes the register callback directly, so
/// no loop is needed to exercise the dispatch.
final class _LoopCapture {
  final executors = <String, ContextToolExecutor>{};
  void register(String name, ContextToolExecutor exec) =>
      executors[name] = exec;
}

final class _PausedFileSystem extends IoFileSystem {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> writeFile(String path, String content) async {
    started.complete();
    await release.future;
    await super.writeFile(path, content);
  }
}
