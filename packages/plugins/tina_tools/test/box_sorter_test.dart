// The box sorter: the whole rule as one pure function — a request plus an
// injected context in, a box plus a suggested profile out. Unknown
// constructs and anything a profile cannot contain fall to box 3; the
// sorter never guesses in favor of silence.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

ProcessRequest _exec(String program, List<String> arguments,
        {String? cwd}) =>
    (
      command: program,
      arguments: arguments,
      workingDirectory: cwd,
      environment: null,
      stdin: null,
      timeout: null,
    );

ProcessRequest _shell(String script) => _exec('/bin/sh', ['-c', script]);

const _context = (
  workspaceRoot: '/workspace',
  confined: true,
  networkRequested: false,
  readOnlyRequested: null,
  outsideSandboxRequested: false,
  declaredReads: <String>[],
  declaredWrites: <String>[],
  certifiedReadOnly: false,
  verifiedReads: <String>[],
  canRead: _canRead,
  canWrite: _canWrite,
  allowlist: null,
);

bool _canRead(String path) => path.startsWith('/opt/reads');
bool _canWrite(String path) => path.startsWith('/opt/writes');

BoxDecision _sort(ProcessRequest request, [BoxSortContext context = _context]) =>
    sortBox(request, context: context);

BoxSortContext _with({
  bool? confined,
  bool? networkRequested,
  bool? readOnlyRequested,
  bool? outsideSandboxRequested,
  List<String>? declaredReads,
  List<String>? declaredWrites,
  bool? certifiedReadOnly,
  List<String>? verifiedReads,
  BoxAllowlist? allowlist,
}) =>
    (
      workspaceRoot: '/workspace',
      confined: confined ?? _context.confined,
      networkRequested: networkRequested ?? _context.networkRequested,
      readOnlyRequested: readOnlyRequested ?? _context.readOnlyRequested,
      outsideSandboxRequested:
          outsideSandboxRequested ?? _context.outsideSandboxRequested,
      declaredReads: declaredReads ?? const [],
      declaredWrites: declaredWrites ?? const [],
      certifiedReadOnly: certifiedReadOnly ?? false,
      verifiedReads: verifiedReads ?? const [],
      canRead: _canRead,
      canWrite: _canWrite,
      allowlist: allowlist,
    );

void main() {
  group('box 1 — read-only containment, never asks', () {
    test('unclassified programs run read-only', () {
      final decision = _sort(_exec('cat', ['README.md']));
      expect(decision.box, Box.readOnly);
      expect(decision.profile, boxProfileDefault);
    });

    test('read-only subcommands of write-capable tools stay box 1', () {
      expect(_sort(_exec('git', ['status'])).box, Box.readOnly);
      expect(_sort(_exec('git', ['log', '--oneline'])).box, Box.readOnly);
      expect(_sort(_exec('sed', ['-n', '2p', 'file.txt'])).box, Box.readOnly);
    });

    test('a certified reader pipeline is box 1 with verified reads visible',
        () {
      final decision = _sort(
          _exec('rg', ['pattern', 'lib/']),
          _with(certifiedReadOnly: true, verifiedReads: ['/workspace/lib']));
      expect(decision.box, Box.readOnly);
    });

    test('certified reads outside the visible world ask', () {
      final decision = _sort(
          _exec('rg', ['pattern', '/etc/secrets']),
          _with(certifiedReadOnly: true, verifiedReads: ['/etc/secrets']));
      expect(decision.box, Box.ask);
    });

    test('an explicit read-only request is box 1 for any program', () {
      final decision =
          _sort(_exec('unknown-tool', []), _with(readOnlyRequested: true));
      expect(decision.box, Box.readOnly);
    });

    test('pipelines of readers stay box 1', () {
      final decision = _sort(_shell("cat a.txt | grep x | wc -l"));
      expect(decision.box, Box.readOnly);
    });
  });

  group('box 2 — profile-fitted containment, silent', () {
    test('inline interpreter scripts use the scripts profile', () {
      for (final script in [
        "python3 -c 'print(1)'",
        "python3 -c \"import os\"",
        "node -e 'console.log(1)'",
        "perl -e 'print 1'",
      ]) {
        final decision = _sort(_shell(script));
        expect(decision.box, Box.contained, reason: script);
        expect(decision.profile, boxProfileScripts, reason: script);
      }
    });

    test('heredoc scripts use the scripts profile', () {
      for (final script in [
        "python3 - <<'PY'\nprint(1)\nPY",
        'python3 - <<PY\nprint(1)\nPY',
        "python3 - << PY\nprint(1)\nPY",
        "node --input-type=module - <<'JS'\nconsole.log(1)\nJS",
        "python3 - <<-PY\n\tprint(1)\n\tPY",
      ]) {
        final decision = _sort(_shell(script));
        expect(decision.box, Box.contained, reason: script);
        expect(decision.profile, boxProfileScripts, reason: script);
      }
    });

    test('an interpreter script file in the workspace uses scripts', () {
      final decision = _sort(_exec('python3', ['tool/run.py']));
      expect(decision.box, Box.contained);
      expect(decision.profile, boxProfileScripts);
    });

    test('build and test families use the build profile', () {
      for (final request in [
        _exec('dart', ['test', 'packages/tina_core']),
        _exec('dart', ['analyze']),
        _exec('cargo', ['build', '--release']),
        _exec('go', ['test', './...']),
        _exec('make', []),
        _exec('pytest', []),
      ]) {
        final decision = _sort(request);
        expect(decision.box, Box.contained, reason: request.command);
        expect(decision.profile, boxProfileBuild, reason: request.command);
      }
    });

    test('write-capable git subcommands use the build profile', () {
      expect(_sort(_exec('git', ['add', '-A'])).profile, boxProfileBuild);
      expect(_sort(_exec('git', ['commit', '-m', 'x'])).profile,
          boxProfileBuild);
      expect(_sort(_exec('git', ['checkout', '-b', 'x'])).profile,
          boxProfileBuild);
    });

    test('a file redirect upgrades the profile to build', () {
      final decision = _sort(_shell("cat a.txt > out.txt"));
      expect(decision.box, Box.contained);
      expect(decision.profile, boxProfileBuild);
    });

    test('declared write directories upgrade scripts to build', () {
      final decision = _sort(_exec('python3', ['deploy.py']),
          _with(declaredWrites: ['/workspace/site']));
      expect(decision.box, Box.contained);
      expect(decision.profile, boxProfileBuild);
    });

    test('package fetches with a network declaration use packages', () {
      for (final request in [
        _exec('dart', ['pub', 'get']),
        _exec('flutter', ['pub', 'get']),
        _exec('cargo', ['fetch']),
        _exec('go', ['mod', 'download']),
        _exec('npm', ['install']),
        _exec('pip', ['install', 'requests']),
        _exec('python3', ['-m', 'pip', 'install', 'flask']),
      ]) {
        final decision = _sort(request, _with(networkRequested: true));
        expect(decision.box, Box.contained, reason: request.command);
        expect(decision.profile, boxProfilePackages, reason: request.command);
      }
    });

    test('package fetches without network run in the build profile', () {
      final decision = _sort(_exec('dart', ['pub', 'get']));
      expect(decision.box, Box.contained);
      expect(decision.profile, boxProfileBuild);
    });

    test('mixed pipelines take the profile that covers every component',
        () {
      expect(_sort(_shell("python3 -c 'print(1)' | cat")).profile,
          boxProfileScripts);
      expect(_sort(_shell("cat a.txt | dart format")).profile,
          boxProfileBuild);
      expect(_sort(_shell("cargo build && cargo test")).profile,
          boxProfileBuild);
    });
  });

  group('box 3 — asks', () {
    test('raw network programs ask', () {
      for (final request in [
        _exec('curl', ['https://example.com']),
        _exec('wget', ['http://example.com/f']),
        _exec('ssh', ['host', 'uptime']),
        _exec('git', ['fetch', 'origin']),
        _exec('git', ['push']),
      ]) {
        expect(_sort(request).box, Box.ask, reason: request.command);
      }
    });

    test('a network declaration on a non-packages family asks', () {
      expect(_sort(_exec('cat', []), _with(networkRequested: true)).box,
          Box.ask);
      expect(
          _sort(_exec('python3', ['-c', 'fetch()']),
                  _with(networkRequested: true))
              .box,
          Box.ask);
    });

    test('destructive commands ask, always', () {
      for (final request in [
        _exec('rm', ['-rf', 'build/']),
        _exec('rmdir', ['old']),
        _exec('truncate', ['-s', '0', 'log']),
        _exec('git', ['push', '--force']),
        _exec('git', ['clean', '-fdx']),
        _exec('dd', ['of=/dev/sda']),
      ]) {
        expect(_sort(request).box, Box.ask, reason: request.command);
      }
    });

    test('unknown shell constructs ask', () {
      for (final script in [
        r'echo $(whoami)',
        'echo `whoami`',
        'cat a || cat b',
        'ls *',
        '(cd /tmp && ls)',
        'echo {a,b}',
        'cat < input.txt',
        'cat a.txt | python3 -c "x" | tee /log',
      ]) {
        expect(_sort(_shell(script)).box, Box.ask, reason: script);
      }
    });

    test('an unterminated heredoc asks', () {
      expect(_sort(_shell("python3 - <<'PY'\nprint(1)")).box, Box.ask);
      expect(_sort(_shell("python3 - <<'PY'\nprint(1)\nPY\necho after")).box,
          Box.ask);
    });

    test('operands outside the visible world ask', () {
      expect(_sort(_exec('cat', ['/etc/shadow'])).box, Box.ask);
      expect(_sort(_exec('cat', ['../outside.txt'])).box, Box.ask);
      // A granted read directory is visible.
      expect(_sort(_exec('cat', ['/opt/reads/data'])).box, Box.readOnly);
    });

    test('a working directory outside the workspace asks', () {
      expect(
          _sort(_exec('cat', ['notes'], cwd: '/opt/reads'), _with()).box,
          Box.readOnly);
      expect(_sort(_exec('cat', ['notes'], cwd: '/opt')).box, Box.ask);
    });

    test('declared directories outside the profile world ask', () {
      expect(
          _sort(_exec('dart', ['test']),
                  _with(declaredReads: ['/opt/other'])).box,
          Box.ask);
      expect(
          _sort(_exec('dart', ['test']),
                  _with(declaredWrites: ['/opt/other'])).box,
          Box.ask);
      expect(
          _sort(_exec('dart', ['test']),
                  _with(declaredWrites: ['/opt/writes/cache'])).box,
          Box.contained);
    });

    test('outside-sandbox requests ask', () {
      expect(_sort(_exec('cargo', ['build']),
              _with(outsideSandboxRequested: true)).box,
          Box.ask);
    });

    test('no confinement backend means the existing path owns it', () {
      expect(_sort(_exec('cat', ['a']), _with(confined: false)).box, Box.ask);
      expect(
          _sort(_exec('python3', ['-c', 'x']), _with(confined: false)).box,
          Box.ask);
    });
  });

  group('the allowlist decides first', () {
    late Directory fixture;
    setUp(() {
      fixture = Directory.systemTemp.createTempSync('box-sorter-');
      addTearDown(() => fixture.deleteSync(recursive: true));
    });

    BoxAllowlist _allowlist() =>
        BoxAllowlist.load(project: File('${fixture.path}/box_allowlist'));

    test('a stored rule runs matches in its named box', () {
      final allowlist = _allowlist()
        ..remember('curl*', Box.contained, boxProfilePackages);
      expect(_sort(_exec('curl', ['https://a.dev']), _with(allowlist: allowlist)).box,
          Box.contained);
      expect(
          _sort(_exec('curl', ['https://a.dev']),
                  _with(allowlist: allowlist))
              .profile,
          boxProfilePackages);
    });

    test('a stored box-1 rule silences matches', () {
      final allowlist = _allowlist()..remember('vendor-tool*', Box.readOnly, null);
      expect(_sort(_exec('vendor-tool', ['--report']), _with(allowlist: allowlist)).box,
          Box.readOnly);
    });

    test('a stored ask rule keeps asking', () {
      final allowlist = _allowlist()..remember('curl http*', Box.ask, null);
      expect(_sort(_exec('curl', ['http://a.dev']), _with(allowlist: allowlist)).box,
          Box.ask);
    });

    test('destructive commands ask even when a rule matches', () {
      final allowlist = _allowlist()
        ..remember('rm *', Box.contained, boxProfileBuild);
      expect(_sort(_exec('rm', ['-rf', '/']), _with(allowlist: allowlist)).box,
          Box.ask);
    });

    test('stored rules are consulted before family classification', () {
      final allowlist = _allowlist()..remember('dart *', Box.readOnly, null);
      expect(
          _sort(_exec('dart', ['test']),
                  _with(allowlist: allowlist)).box,
          Box.readOnly);
    });
  });
}
