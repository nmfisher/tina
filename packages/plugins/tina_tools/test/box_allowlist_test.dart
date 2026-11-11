// The box allowlist: the one list. Plain text, versioned, user-editable;
// project rules before global rules; damaged lines reported, never fatal.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  late Directory fixture;
  late File project;
  late File global;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('box-allowlist-');
    project = File('${fixture.path}/project/box_allowlist');
    global = File('${fixture.path}/home/box_allowlist');
    addTearDown(() {
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });
  });

  test('rule lines round-trip through parse and format', () {
    expect(parseBoxRule('dart test* -> 2/build')?.verdict, '2/build');
    expect(parseBoxRule('vendor-tool* -> 1')?.verdict, '1');
    expect(parseBoxRule('curl http* -> 3')?.verdict, '3');
    expect(formatBoxRule('dart test*', Box.contained, boxProfileBuild),
        'dart test* -> 2/build');
    expect(formatBoxRule('x*', Box.readOnly, null), 'x* -> 1');
    expect(formatBoxRule('x*', Box.ask, null), 'x* -> 3');
    for (final broken in [
      '',
      'no arrow',
      '-> 2/build',
      'x ->',
      'x -> 2/unknown-profile',
      'x -> 2/',
      'x -> 4',
      'x -> build',
    ]) {
      expect(parseBoxRule(broken), isNull, reason: '"$broken"');
    }
  });

  test('missing files are an empty list', () {
    final allowlist = BoxAllowlist.load(project: project, global: global);
    expect(allowlist.rules, isEmpty);
    expect(allowlist.errors, isEmpty);
    expect(allowlist.match('dart test'), isNull);
  });

  test('remember writes the versioned header and the rule', () {
    final allowlist = BoxAllowlist.load(project: project, global: global);
    allowlist
      ..remember('dart test*', Box.contained, boxProfileBuild)
      ..remember('vendor-tool*', Box.readOnly, null, global: true);
    final text = project.readAsStringSync();
    expect(text, startsWith('# tina box allowlist v1\n'));
    expect(text, contains('version 1'));
    expect(text, contains('dart test* -> 2/build'));
    expect(global.readAsStringSync(), contains('vendor-tool* -> 1'));
    // A fresh load reads both back.
    final reloaded = BoxAllowlist.load(project: project, global: global);
    expect(reloaded.rules.map((rule) => rule.verdict),
        containsAll(['2/build', '1']));
    expect(reloaded.errors, isEmpty);
  });

  test('project rules are consulted before global rules', () {
    project.parent.createSync(recursive: true);
    global.parent.createSync(recursive: true);
    project.writeAsStringSync('version 1\ncurl* -> 3\n');
    global.writeAsStringSync('version 1\ncurl* -> 2/packages\n');
    final allowlist = BoxAllowlist.load(project: project, global: global);
    final rule = allowlist.match('curl https://example.com');
    expect(rule, isNotNull);
    expect(rule!.box, Box.ask);
  });

  test('patterns match command lines with glob semantics', () {
    project.parent.createSync(recursive: true);
    project.writeAsStringSync('version 1\n'
        'dart test* -> 2/build\n'
        'cargo * -> 2/build\n'
        'python3 * -> 2/scripts\n');
    final allowlist = BoxAllowlist.load(project: project);
    expect(allowlist.match('dart test'), isNotNull);
    expect(allowlist.match('dart test packages/tina_core'), isNotNull);
    expect(allowlist.match('dart analyze'), isNull);
    expect(allowlist.match('cargo build --release'), isNotNull);
    expect(allowlist.match('cargo'), isNull);
    expect(allowlist.match('python3 -c "print(1)"'), isNotNull);
  });

  test('edits on disk take effect on the next match', () {
    final allowlist = BoxAllowlist.load(project: project);
    expect(allowlist.match('go test ./...'), isNull);
    allowlist.remember('go *', Box.contained, boxProfileBuild);
    expect(allowlist.match('go test ./...'), isNotNull);
    project.writeAsStringSync('version 1\n');
    expect(BoxAllowlist.load(project: project).match('go test ./...'),
        isNull);
  });

  test('a missing version header ignores the whole file and reports', () {
    project.parent.createSync(recursive: true);
    project.writeAsStringSync('dart test* -> 2/build\n');
    final allowlist = BoxAllowlist.load(project: project);
    expect(allowlist.rules, isEmpty);
    expect(allowlist.errors, hasLength(1));
    expect(allowlist.errors.single, contains('version 1'));
  });

  test('damaged rules are skipped and reported, not fatal', () {
    project.parent.createSync(recursive: true);
    project.writeAsStringSync('version 1\n'
        'fine* -> 1\n'
        'broken line without arrow\n'
        'bad -> 2/nope\n'
        'also fine -> 3\n');
    final allowlist = BoxAllowlist.load(project: project);
    expect(allowlist.rules, hasLength(2));
    expect(allowlist.errors, hasLength(2));
    expect(allowlist.match('fine command'), isNotNull);
    expect(allowlist.match('bad command'), isNull);
  });

  test('remember refuses lines the loader could not read back', () {
    final allowlist = BoxAllowlist.load(project: project);
    expect(() => allowlist.remember('no arrow here', Box.contained, null),
        throwsFormatException);
  });

  test('dialog regexes translate to globs, richer ones do not', () {
    expect(globFromDialogPattern(r'curl .*'), 'curl *');
    expect(globFromDialogPattern(r'dart test .*'), 'dart test *');
    expect(globFromDialogPattern(r'prefix.*middle.*suffix'),
        'prefix*middle*suffix');
    expect(globFromDialogPattern('.*'), '*');
    expect(globFromDialogPattern(r'git status --porcelain'),
        'git status --porcelain');
    // Escapes the dialog's default (RegExp.escape) produces are unescaped.
    expect(globFromDialogPattern(r'echo a\.b'), 'echo a.b');
    for (final tooRich in [
      r'curl (foo|bar)', // alternation
      'curl [abc]', // character class
      r'cu.l x', // bare any-char dot
      'curl ^x', // anchors
      'curl x{2}', // repetition
      '', // empty
    ]) {
      expect(globFromDialogPattern(tooRich), isNull, reason: tooRich);
    }
    // The translated glob matches the command the dialog validated.
    expect(boxPatternMatch(globFromDialogPattern(r'curl .*')!, 'curl -sI x'),
        isTrue);
  });

  test('the default file locations are documented paths', () {
    expect(boxAllowlistProjectPath('/work/proj'), '/work/proj/.tina/box_allowlist');
    expect(boxAllowlistGlobalPath('/home/dev'), '/home/dev/.tina/box_allowlist');
  });
}
