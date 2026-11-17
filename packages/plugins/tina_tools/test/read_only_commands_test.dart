import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/src/read_only_commands.dart';
import 'package:tina_tools/tina_tools.dart';

import 'support/reader_fixtures.dart';

ProcessRequest request(String program, List<String> args,
        {String? cwd, Map<String, String>? environment}) =>
    (
      command: program,
      arguments: args,
      workingDirectory: cwd,
      environment: environment,
      stdin: null,
      timeout: null
    );

// Recognition reports effects; it never grants execution permission.
void main() {
  late Directory root;
  late ReaderFixtures readers;
  setUpAll(() async {
    // Certification only trusts binaries that resolve to /bin|/usr/bin
    // names; runner images that resolve coreutils through renamed
    // multi-call files (rm → …/gnurm) make real-system certification
    // null BY DESIGN. Tests here assert the recognition logic, not the
    // host's /usr/bin topology, so they pin fixture binaries through the
    // same version-pinned hash table production supports.
    readers = await ReaderFixtures.create([
      'find', 'git', 'sed', 'ls', 'grep', 'cat', 'echo', 'head'
    ]);
  });
  tearDownAll(() => readers.directory.deleteSync(recursive: true));
  setUp(() => root = Directory(Directory.systemTemp
      .createTempSync('reader-parser-')
      .resolveSymbolicLinksSync()));
  tearDown(() => root.deleteSync(recursive: true));
  test('oversized reader binaries fall back to exact approval', () {
    final executable = File('${root.path}/rg');
    final handle = executable.openSync(mode: FileMode.write);
    try {
      handle.truncateSync(64 * 1024 * 1024 + 1);
    } finally {
      handle.closeSync();
    }
    Process.runSync('/bin/chmod', ['+x', executable.path]);
    expect(
        readOnlyExecutable(request(executable.path, ['--files']),
            candidateOnly: true),
        isNull);
  }, skip: Platform.isWindows);

  test('constrained find and reader options reject execution and write flags',
      () {
    for (final arguments in [
      ['.', '-name', '*.dart', '-type', 'f', '-print'],
      ['.', '-maxdepth', '2', '-not', '-name', '*.g.dart']
    ]) {
      expect(
          readOnlyExecutable(request('find', arguments),
              searchPath: readers.searchPath,
              trustedExecutables: readers.trusted),
          isNotNull);
    }
    for (final arguments in [
      ['.', '-delete'],
      ['.', '-exec', 'touch', 'bad', ';'],
      ['.', '-fprint', 'bad'],
      ['-L', '.']
    ]) {
      expect(
          readOnlyExecutable(request('find', arguments),
              searchPath: readers.searchPath,
              trustedExecutables: readers.trusted),
          isNull);
    }
    for (final arguments in [
      ['--pre=touch bad', 'needle'],
      ['--hostname-bin=touch', 'needle']
    ]) {
      expect(
          readOnlyExecutable(request('/usr/bin/rg', arguments),
              searchPath: readers.searchPath, candidateOnly: true),
          isNull);
    }
    final protected =
        request('/bin/sh', ['-c', 'echo data > protected'], cwd: root.path);
    expect(
        readOnlyShellRequest(protected,
            searchPath: readers.searchPath,
            trustedExecutables: readers.trusted,
            canWrite: (target) =>
                target != '${root.resolveSymbolicLinksSync()}/protected'),
        isNull);
  }, skip: Platform.isWindows);

  test('system absolute paths also work, with no basename-only trust', () {
    for (final program in [readers.path('ls'), readers.path('grep')]) {
      expect(
          readOnlyExecutable(request(program, []),
              trustedExecutables: readers.trusted),
          isNotNull);
    }
    for (final program in [
      '${root.path}/ls',
      './grep',
      '/usr/local/bin/grep',
      'sh',
      'bash',
      'env',
      'sed',
      'rg'
    ]) {
      expect(readOnlyExecutable(request(program, ['file'])), isNull);
    }
  });

  test('read-only git subcommands certify; writing ones and options ask', () {
    for (final args in [
      ['status'],
      ['status', '-sb'],
      ['diff'],
      ['diff', 'HEAD~1'],
      ['log'],
      ['log', '-3'],
      ['show'],
      ['show', 'HEAD'],
      ['show', 'HEAD:pubspec.yaml'],
      ['branch', '-a'],
      ['tag', '-l'],
      ['status', '--porcelain=v1'],
      ['log', '--format=%H'],
      ['status', '--']
    ]) {
      expect(
          readOnlyExecutable(request('git', args),
              searchPath: readers.searchPath,
              trustedExecutables: readers.trusted),
          isNotNull,
          reason: 'git ${args.join(' ')}');
    }
    for (final args in <List<String>>[
      ['push'],
      ['commit'],
      ['reset', '--hard'],
      ['add', '.'],
      ['checkout', 'main'],
      ['branch', 'feature'],
      ['branch', '-d', 'feature'],
      ['tag', 'v1.0.0'],
      ['tag', '-a', 'v1', '-m', 'msg'],
      ['log', '-n', '5'],
      ['log', '-S', 'needle'],
      ['diff', '-O', 'orderfile'],
      ['-C', '/tmp', 'status'],
      ['-c', 'core.fsmonitor=true', 'status'],
      ['show', '--output=/tmp/x'],
      ['tag', '--', 'new-tag'],
      ['branch', '--', 'new-branch'],
      []
    ]) {
      expect(
          readOnlyExecutable(request('git', args),
              searchPath: readers.searchPath,
              trustedExecutables: readers.trusted),
          isNull,
          reason: 'git ${args.join(' ')}');
    }
  });

  test('print-only sed certifies; edits and scripts that write ask', () {
    for (final args in [
      ['-n', '180,215p', 'file.py'],
      ['-n', '5p', 'file.py'],
      ['-n', 'p', 'file.py'],
      ['-n', '10q', 'file.py'],
      ['-n', '180,215p;220q', 'file.py'],
      ['-n', r'$p', 'file.py']
    ]) {
      expect(
          readOnlyExecutable(request('sed', args),
              searchPath: readers.searchPath,
              trustedExecutables: readers.trusted),
          isNotNull,
          reason: 'sed ${args.join(' ')}');
    }
    for (final args in [
      ['-i', 's/a/b/', 'file'],
      ['s/a/b/', 'file'],
      ['-n', 's/a/b/p', 'file'],
      ['-n', '180,215s/x/y/p', 'file'],
      ['-n', 'w /tmp/out', 'file'],
      ['-n', 'e touch WRITTEN', 'file'],
      ['-f', 'script.sed', 'file'],
      ['--output=/tmp/out'],
      ['-n', '--quiet', '180,215p', 'file'],
      ['-n', '180,215p;w /tmp/out', 'file'],
      ['-n', 'p # comment', 'file']
    ]) {
      expect(
          readOnlyExecutable(request('sed', args),
              searchPath: readers.searchPath,
              trustedExecutables: readers.trusted),
          isNull,
          reason: 'sed ${args.join(' ')}');
    }
  });
  test('relocated system readers certify; writable redirects stay refused',
      () {
    // Runner images migrating coreutils to renamed multi-call files
    // resolve `/usr/bin/cat` to `…/gnucat`. Certification must follow the
    // target as long as it still lives inside the (root-owned) system
    // trees, while a system-name symlink into a writable directory keeps
    // being refused. CI run 44026685951: the Remember/invocation-access
    // family failed exactly through the empty reader-access lists this
    // gate produced on such hosts.
    final system = Directory('${root.path}/system')..createSync();
    final writable = Directory('${root.path}/writable')..createSync();
    final target = File('${system.path}/gnucat')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    final chmod = Process.runSync('/bin/chmod', ['+x', target.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    Link('${system.path}/cat').createSync(target.path);
    File('${writable.path}/evil').writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('/bin/chmod', ['+x', '${writable.path}/evil']);
    Link('${system.path}/grep').createSync('${writable.path}/evil');
    // The relocated reader certifies through its system-resident target.
    expect(
        readOnlyExecutable(request('${system.path}/cat', ['a', 'b']),
            systemDirectories: [system.path]),
        target.path);
    // A system-name symlink that leaves the system trees is refused.
    expect(
        readOnlyExecutable(request('${system.path}/grep', ['needle']),
            systemDirectories: [system.path]),
        isNull);
  });

  test('shell parsing preserves quoted words and operators', () {
    final parts = literalShellParts(
        request('/bin/sh', ['-c', 'echo "a b" | wc -c && cat file']));
    expect(parts, hasLength(3));
    expect(parts!.first.words, ['echo', 'a b']);
    expect(parts.first.operator, '|');
    expect(parts[1].operator, '&&');
  });
  test('shell parsing never expands substitutions or wildcard operands', () {
    for (final script in [
      r'echo $(whoami)',
      'echo `whoami`',
      'ls *',
      'cat a || cat b'
    ]) {
      expect(literalShellParts(request('/bin/sh', ['-c', script])), isNull);
    }
  });
}
