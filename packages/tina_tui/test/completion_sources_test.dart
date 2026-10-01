// The input line's completion: the `/` command source (registry names)
// and the `@` file source (full git listing, directory walk fallback), plus
// the buffer surgery the editor performs when a candidate is accepted.
//
// The picker machinery is `tina_console`'s and is tested there; what is
// tina_tui's is tested here: the two sources themselves and the wiring
// in runApp — typed keystrokes drive a real LineEditor over a fake
// Stdio, exactly as the app loop does.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:io';

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:test/test.dart';

/// A fake [Stdio]: an in-memory byte feed, a captured buffer — the seam
/// the app's loop reads keystrokes from.
final class FlushIo implements Stdio {
  final _controller = StreamController<List<int>>(sync: true);
  final written = StringBuffer();
  int columns = 80;
  final lines = 24;

  void feedBytes(List<int> bytes) => _controller.add(bytes);

  void closeInput() => _controller.close();

  @override
  Stream<List<int>> get stdin => _controller.stream;

  @override
  void write(String s) => written.write(s);

  @override
  int get terminalColumns => columns;

  @override
  bool get hasTerminal => false;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) =>
      const Stream<ProcessSignal>.empty();
}

/// One fixed result list for every query — the picker's asynchronous
/// refresh is what these tests exercise, not ranking.
final class StaticSource implements CompletionProvider {
  final List<String> results;
  StaticSource(this.results);

  @override
  Future<List<String>> complete(String query) async => results;
}

/// Pump microtasks and one timer turn so the editor's scheduled picker
/// refreshes have landed before the next keystroke.
Future<void> flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

LineEditor editorWith(FlushIo io, {CompletionProvider? commands, files}) {
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(io.columns, io.lines),
  );
  final ed = LineEditor(
    screen: screen,
    escapeTimeout: Duration.zero,
  );
  ed.completionProvider = files;
  ed.commandProvider = commands;
  return ed;
}

Commands registryWith(List<String> names) {
  final c = Commands();
  for (final n in names) {
    c.publish(Command(name: n, description: 'the $n command', handler: (_) {}));
  }
  return c;
}

/// A scratch git repository with [files] written into it (untracked —
/// `ls-files --others` lists those without a commit).
Directory gitRepoWith(List<String> files) {
  final dir = Directory.systemTemp.createTempSync('tina_tui_completion_');
  final init = Process.runSync('git', ['init', dir.path]);
  if (init.exitCode != 0) {
    throw StateError('git init failed: ${init.stderr}');
  }
  for (final f in files) {
    final file = File('${dir.path}/$f');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x\n');
  }
  return dir;
}

void main() {
  test('argument completion is supplied by the live command registration',
      () async {
    final commands = Commands();
    commands.publish(Command(
        name: 'example',
        description: 'example',
        handler: (_) {},
        complete: (prefix) => ['alpha', 'beta']
            .where((word) => word.startsWith(prefix))
            .toList()));
    final source = CommandNameCompletionSource(commands);
    expect(await source.complete('example b'), ['/example beta']);
    expect(await source.complete('unknown b'), isEmpty);
  });

  late Directory ws;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_tui_completion_ws_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  group('the / command source reads the registry', () {
    test('a prefix returns the registered command names', () async {
      final source =
          CommandNameCompletionSource(registryWith(['mode', 'quit']));
      expect(await source.complete('m'), ['/mode']);
      expect(await source.complete('q'), ['/quit']);
      expect(await source.complete('mode'), ['/mode']);
      // No slash in the query is still interpreted as the command word.
      expect(await source.complete(''), ['/mode', '/quit']);
    });

    test('published-after-construction names still suggest (read at use)',
        () async {
      final registry = registryWith(['mode']);
      final source = CommandNameCompletionSource(registry);
      registry.publish(Command(name: 'zap', description: 'z', handler: (_) {}));
      expect(await source.complete('z'), ['/zap']);
    });

    test('an unknown prefix is an empty list, never an error', () async {
      final source = CommandNameCompletionSource(registryWith(['mode']));
      expect(await source.complete('nope'), isEmpty);
    });
  });

  group('the @ file source', () {
    test('returns paths for a prefix inside a temporary git repository',
        () async {
      final repo = gitRepoWith(['README.md', 'lib/main.dart', 'lib/util.dart']);
      try {
        final source = GitFileCompletionSource(workingDir: repo.path);
        expect(await source.complete('main'), contains('lib/main.dart'));
        expect(await source.complete('READ'), ['README.md']);
        // The bare trigger lists the full candidate set.
        final all = await source.complete('');
        expect(all, containsAll(['README.md', 'lib/main.dart']));
      } finally {
        repo.deleteSync(recursive: true);
      }
    });

    test('an empty directory is an empty list, not an error', () async {
      final repo = gitRepoWith([]);
      try {
        final source = GitFileCompletionSource(workingDir: repo.path);
        expect(await source.complete('anything'), isEmpty);
        expect(await source.complete(''), isEmpty);
      } finally {
        repo.deleteSync(recursive: true);
      }
    });

    test('outside a repository is an empty list, not an error', () async {
      // ws is a plain temp directory: no .git anywhere above it that a
      // fresh temp path could belong to. An empty folder: nothing to
      // walk either. Both empties must arrive as lists.
      final source = GitFileCompletionSource(workingDir: ws.path);
      expect(await source.complete('main'), isEmpty);
      expect(await source.complete(''), isEmpty);
    });

    test('outside a repository the walk supplies the candidates', () async {
      // A populated non-repo folder: the walk fallback enumerates it.
      File('${ws.path}/notes.txt').writeAsStringSync('x\n');
      Directory('${ws.path}/docs').createSync();
      File('${ws.path}/docs/guide.md').writeAsStringSync('x\n');
      final source = GitFileCompletionSource(workingDir: ws.path);
      final all = await source.complete('');
      expect(all, contains('notes.txt'));
      expect(all, contains('docs/guide.md'));
      expect(await source.complete('guide'), contains('docs/guide.md'));
    });

    test('bare @ and fuzzy searches retain every file beyond the old 200 cap',
        () async {
      final files = [
        for (var i = 0; i < 550; i++) '.tickets/f$i.txt',
        'lib/zzz_unique_target.dart',
        'docs/guide.md',
        'README.md'
      ];
      final repo = gitRepoWith(files);
      try {
        final source = GitFileCompletionSource(workingDir: repo.path);
        final all = await source.complete('');
        expect(all.toSet(), files.toSet());
        expect(
            all.take(8),
            containsAll(
                ['lib/zzz_unique_target.dart', 'docs/guide.md', 'README.md']));
        expect(await source.complete('unique_target'),
            ['lib/zzz_unique_target.dart']);
        expect(await source.complete('f549'), contains('.tickets/f549.txt'));
        expect(await source.complete('tickets'), hasLength(550));
      } finally {
        repo.deleteSync(recursive: true);
      }
    });
    test(
        'git returns actual Unicode, whitespace and quoted filenames, honoring ignore rules',
        () async {
      final files = [
        'docs/café 日本語.md',
        'docs/white space.md',
        'docs/quote"name.md',
        'docs/tab\tname.md',
        'docs/line\nbreak.md',
        '.hidden',
        'LICENSE',
        '.gitignore',
        'ignored.txt',
        'tracked.txt'
      ];
      final repo = gitRepoWith(files);
      try {
        File('${repo.path}/.gitignore')
            .writeAsStringSync('ignored.txt\ntracked.txt\n');
        final add = Process.runSync('git', ['add', '-f', 'tracked.txt'],
            workingDirectory: repo.path);
        expect(add.exitCode, 0);
        final source = GitFileCompletionSource(workingDir: repo.path);
        expect((await source.complete('')).toSet(),
            files.where((f) => f != 'ignored.txt').toSet());
        expect(await source.complete('café'), ['docs/café 日本語.md']);
        expect(await source.complete('white space'), ['docs/white space.md']);
      } finally {
        repo.deleteSync(recursive: true);
      }
    });
    test('walk searches more than 200 files and deeper than eight directories',
        () async {
      for (var i = 0; i < 240; i++) {
        File('${ws.path}/f$i.txt').writeAsStringSync('x');
      }
      final deep = '${List.filled(12, 'nested').join('/')}/deep_target.dart';
      File('${ws.path}/$deep')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${ws.path}/build/generated.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${ws.path}/.hidden')..writeAsStringSync('x');
      File('${ws.path}/dist')..writeAsStringSync('a regular source file');
      Link('${ws.path}/cycle').createSync(ws.path);
      final source = GitFileCompletionSource(workingDir: ws.path);
      final all = await source.complete('');
      expect(all, hasLength(244)); // 240 + deep + hidden + file + symlink
      expect(all, containsAll([deep, '.hidden', 'dist', 'cycle']));
      expect(all, isNot(contains('build/generated.dart')));
      expect(all.any((file) => file.startsWith('cycle/')), false);
      expect(await source.complete('deep_target'), [deep]);
    });
    test(
        'stale snapshots refresh and concurrent keystrokes share the fresh listing',
        () async {
      var now = DateTime(2026);
      File('${ws.path}/old.dart').writeAsStringSync('x');
      final source =
          GitFileCompletionSource(workingDir: ws.path, clock: () => now);
      expect(await source.complete(''), ['old.dart']);
      File('${ws.path}/old.dart').renameSync('${ws.path}/new.dart');
      now = now.add(const Duration(seconds: 1));
      expect(await source.complete(''), ['old.dart']);
      now = now.add(const Duration(seconds: 3));
      final snapshots =
          await Future.wait([source.complete(''), source.complete('new')]);
      expect(snapshots, [
        ['new.dart'],
        ['new.dart']
      ]);
    });
    test(
        'initialized nested gitlinks list tracked and untracked files with local ignores',
        () async {
      final repo = gitRepoWith(['root.txt']);
      try {
        final child = Directory('${repo.path}/vendor/dependency')
          ..createSync(recursive: true);
        final nested = Directory('${child.path}/nested/module')
          ..createSync(recursive: true);
        void git(Directory directory, List<String> arguments) {
          final result = Process.runSync('git', arguments,
              workingDirectory: directory.path);
          expect(result.exitCode, 0, reason: result.stderr.toString());
        }

        for (final directory in [nested, child]) {
          git(directory, ['init']);
          File('${directory.path}/tracked.dart').writeAsStringSync('x');
          git(directory, ['add', 'tracked.dart']);
          git(directory, [
            '-c',
            'user.name=Completion test',
            '-c',
            'user.email=test@example.test',
            '-c',
            'commit.gpgsign=false',
            'commit',
            '-m',
            'fixture'
          ]);
        }
        String head(Directory directory) =>
            (Process.runSync('git', ['rev-parse', 'HEAD'],
                        workingDirectory: directory.path)
                    .stdout as String)
                .trim();
        git(child, [
          'update-index',
          '--add',
          '--cacheinfo',
          '160000',
          head(nested),
          'nested/module'
        ]);
        git(repo, [
          'update-index',
          '--add',
          '--cacheinfo',
          '160000',
          head(child),
          'vendor/dependency'
        ]);
        // Also exercise an uninitialized gitlink with an empty directory.
        Directory('${repo.path}/empty')..createSync();
        git(repo, [
          'update-index',
          '--add',
          '--cacheinfo',
          '160000',
          head(child),
          'empty'
        ]);
        File('${child.path}/.gitignore').writeAsStringSync('ignored.dart\n');
        File('${child.path}/untracked.dart').writeAsStringSync('x');
        File('${child.path}/ignored.dart').writeAsStringSync('x');
        final source = GitFileCompletionSource(workingDir: repo.path);
        expect((await source.complete('')).toSet(), {
          'root.txt',
          'vendor/dependency/.gitignore',
          'vendor/dependency/tracked.dart',
          'vendor/dependency/untracked.dart',
          'vendor/dependency/nested/module/tracked.dart',
        });
        expect(await source.complete('nested/module/tracked'),
            ['vendor/dependency/nested/module/tracked.dart']);
      } finally {
        repo.deleteSync(recursive: true);
      }
    });
  });

  group('commands and paths do not leak into each other', () {
    test('each source answers only from its own world', () async {
      final repo = gitRepoWith(['readme.md']);
      try {
        final commands = CommandNameCompletionSource(registryWith(['mode']));
        final files = GitFileCompletionSource(workingDir: repo.path);

        // A file name is not a command; a command word is not a path.
        expect(await commands.complete('readme'), isEmpty);
        expect(await files.complete('mode'), isEmpty);

        // And each still answers from its own world.
        expect(await commands.complete('mode'), ['/mode']);
        expect(await files.complete('readme'), ['readme.md']);
      } finally {
        repo.deleteSync(recursive: true);
      }
    });
  });

  group('acceptance — the buffer is replaced over the token', () {
    test('a single match is accepted mid-line, over the correct range',
        () async {
      final io = FlushIo();
      final ed = editorWith(io, files: StaticSource(['docs/readme.md']));
      final f = ed.readLine('› ');
      await flush();
      // 'see @readme' — the @ opens the picker mid-line (anchor 4, not 0);
      // the accept must replace exactly [anchor, cursor) and keep the
      // prefix before the token.
      io.feedBytes('see @readme'.codeUnits);
      await flush();
      expect(ed.editState.buffer, 'see @readme');
      io.feedBytes([0x09]); // Tab: accept the highlighted candidate
      await flush();
      // The @ picker prepends its trigger on accept (console semantics —
      // the sigil survives when the token is spliced out of a sentence).
      expect(ed.editState.buffer, 'see @docs/readme.md');
      io.feedBytes([0x0d]); // Enter: submit (picker closed by the accept)
      expect(await f, 'see @docs/readme.md');
      ed.close();
    });

    test('a query with no matches leaves the buffer unchanged', () async {
      final io = FlushIo();
      // Truthful empty results — what the real sources return when the
      // query has no hits.
      final ed = editorWith(io, commands: StaticSource(const []));
      final f = ed.readLine('› ');
      await flush();
      io.feedBytes('/zz'.codeUnits);
      await flush();
      io.feedBytes([0x09]); // Tab with nothing to accept
      await flush();
      expect(ed.editState.buffer, '/zz',
          reason: 'no matches: the buffer must not be touched');
      io.feedBytes([0x0d]); // Enter submits the raw text — no crash, no swap
      expect(await f, '/zz');
      ed.close();
    });
  });

  group('wired through the app loop', () {
    test(
        'the loop builds an editor whose / source names the registry and '
        'whose @ source completes real paths', () async {
      // A file for the @ source to find (the walk fallback supplies it —
      // the temp directory is not a git repository).
      File('${ws.path}/main.dart').writeAsStringSync('x\n');
      for (var i = 0; i < 240; i++) {
        File('${ws.path}/.tickets/ticket-$i.md')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      final provider = ScriptedProvider([scriptedReply('ack')]);
      final io = FlushIo();
      final session = TuiSession.start(
        configPath: '/nonexistent/tina/config',
        providerFactory: (_) => provider,
        workingDirectory: ws.path,
      );
      final done = runApp(
        session,
        screen: Screen(
          io: io,
          layout: ScreenLayout.fromSize(io.columns, io.lines),
        ),
      );
      Future<void> settle([int ms = 120]) =>
          Future<void>.delayed(Duration(milliseconds: ms));

      // '/mod' opens the command picker; Enter ACCEPTS '/mode ' and
      // dispatches it in one key. The tell proves the picker was fed
      // from the registry (a raw '/mod' would have answered 'unknown
      // command: /mod').
      await settle();
      io.feedBytes('/mod'.codeUnits);
      await settle(200); // let the refresh land before Enter
      io.feedBytes([0x0d]);
      await settle(200);

      // 'see @ma' opens the @ picker over the session's working
      // directory; Enter accepts the file candidate, a second Enter
      // submits the turn. The recorded request carries the completed
      // text — the @ source answered with a real path.
      io.feedBytes('see @ma'.codeUnits);
      await settle(200);
      io.feedBytes([0x0d]); // accept
      await settle(100);
      io.feedBytes([0x0d]); // submit
      await settle(200);

      // Buffer is empty again; '/quit' rides accept + submit.
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done.timeout(const Duration(seconds: 10)), 0);
      expect(session.assembly.quitRequested, isTrue);
      final told = (session.terminal as TuiTerminal).lines.map((l) => l.text);
      expect(told, contains('mode: ask'),
          reason: 'the / picker was fed from the Commands registry');
      expect(
        provider.requests.last.messages.last.content
            .whereType<TextBlock>()
            .map((b) => b.text)
            .join(),
        contains('@main.dart'),
        reason: 'the @ picker was fed from the session working directory',
      );
    });
  });
}
