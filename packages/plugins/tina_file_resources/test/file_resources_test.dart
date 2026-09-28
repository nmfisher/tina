import 'dart:convert' show utf8;
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_file_resources/tina_file_resources.dart';

/// Nine cases, in the brief's order:
/// 1. skill discovered and listed
/// 2. model calls read_resource with a known name → body returned
/// 3. read_resource with an unknown name → refusal names available ones
/// 4. empty folder → no section, no tool
/// 5. missing folder → no section, no tool, tool call errors
/// 6. unreadable file → skipped, others work
/// 7. file without header → skipped, others work
/// 8. duplicate names → first wins
/// 9. listing exceeds maxListBytes → visible marker
void main() {
  late Directory dir;
  late FileResourcesPlugin plugin;

  File skillFile(String name, String body) => File('${dir.path}/$name')
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  /// The standard two-file folder, when a case needs contents present.
  void writeStandardFolder() {
    skillFile(
        'alpha.md',
        '---\n'
        'name: alpha\n'
        'description: the first skill\n'
        '---\n'
        'alpha body, verbatim\n'
        'line two\n');
    skillFile(
        'beta.md',
        '---\n'
        'name: beta\n'
        'description: the second skill\n'
        '---\n'
        'beta body\n');
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('file_resources_test');
    plugin = FileResourcesPlugin(
        config: FileResourcesConfig(directory: dir.path));
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('1: skill discovered and listed (name + description, no body)',
      () {
    writeStandardFolder();
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    expect(ctx.promptSections, hasLength(1));
    final section = ctx.promptSections.single;
    expect(section, contains('## Resources'));
    expect(section, contains('- alpha — the first skill'));
    expect(section, contains('- beta — the second skill'));
    expect(section, isNot(contains('alpha body')));
  });

  test('2: read_resource with a known name returns the body', () async {
    writeStandardFolder();
    final result = await plugin.fetch('alpha');
    expect(result.isError, isFalse);
    expect(result.content, 'alpha body, verbatim\nline two');
  });

  test('3: unknown name is refused, naming the available ones',
      () async {
    writeStandardFolder();
    final result = await plugin.fetch('gamma');
    expect(result.isError, isTrue);
    expect(result.content, contains('unknown resource "gamma"'));
    expect(result.content, contains('alpha, beta'));
  });

  test('4: empty folder — no section, no tool', () {
    dir.createSync();
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    expect(ctx.promptSections, isEmpty);
    expect(plugin.tools, isEmpty);
  });

  test('5: missing folder — no section, no tool, fetch errors', () async {
    dir.deleteSync(recursive: true); // the temp dir exists; make it not
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    expect(ctx.promptSections, isEmpty);
    expect(plugin.tools, isEmpty);
    final result = await plugin.fetch('alpha');
    expect(result.isError, isTrue);
    expect(result.content, contains('does not exist'));
  });

  test('6: unreadable file skipped, others still work', () async {
    writeStandardFolder();
    skillFile(
        'locked.md',
        '---\n'
        'name: locked\n'
        'description: will not read\n'
        '---\n'
        'secret body\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['000', '${dir.path}/locked.md']);
    }
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    final section = ctx.promptSections.single;
    expect(section, contains('- alpha —'));
    expect(section, contains('- beta —'));
    final unreadable = plugin.lastListing!.unreadable;
    if (Platform.isWindows || unreadable.isEmpty) {
      // The platform did not enforce the permission (e.g. running as
      // root): the file was read, so it is listed — correct too.
      expect(section, contains('- locked —'));
    } else {
      expect(unreadable, ['locked.md']);
      expect(section, isNot(contains('locked')));
    }
    final result = await plugin.fetch('alpha');
    expect(result.isError, isFalse);
  });

  test('7: file without a valid header skipped, others still work',
      () async {
    writeStandardFolder();
    skillFile('broken.md', 'no front matter here at all\n');
    skillFile(
        'unterminated.md',
        '---\n'
        'name: unterminated\n'
        'description: the fence never closes\n'
        '\n'
        'body text\n');
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    expect(ctx.promptSections.single, contains('- alpha —'));
    expect(ctx.promptSections.single, contains('- beta —'));
    expect(ctx.promptSections.single, isNot(contains('unterminated')));
    expect(plugin.lastListing!.noHeader, containsAll(['broken.md', 'unterminated.md']));
    final result = await plugin.fetch('alpha');
    expect(result.content, 'alpha body, verbatim\nline two');
  });

  test('8: duplicate names — first file wins', () async {
    skillFile(
        'a-dup.md',
        '---\n'
        'name: dup\n'
        'description: first declaration wins\n'
        '---\n'
        'first body\n');
    skillFile(
        'z-dup.md',
        '---\n'
        'name: dup\n'
        'description: shadowed\n'
        '---\n'
        'second body\n');
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    final section = ctx.promptSections.single;
    expect(section, contains('- dup — first declaration wins'));
    expect(section, isNot(contains('shadowed')));
    final result = await plugin.fetch('dup');
    expect(result.content, 'first body');
    expect(plugin.lastListing!.duplicates['dup'],
        ['a-dup.md', 'z-dup.md']);
  });

  test('9: listing over maxListBytes — visible marker, no mid-line cut',
      () {
    for (var i = 0; i < 40; i++) {
      final n = i.toString().padLeft(2, '0');
      skillFile(
          'skill$n.md',
          '---\n'
          'name: skill-$n\n'
          'description: description line for skill $n, padded out so '
          'the listing grows past any small cap\n'
          '---\n'
          'body $n\n');
    }
    final ctx = _Ctx();
    plugin.onPrompt(ctx);
    final section = ctx.promptSections.single;
    expect(utf8.encode(section).length, lessThanOrEqualTo(2048));
    expect(section, contains('more omitted'));
    expect(section, contains('- skill-00 —'));
    expect(section.endsWith('—'), isFalse);
  });
}

/// A prompt-phase context: the plugin under test only writes
/// `promptSections`. Same shape the other packages' tests use.
TurnContext _Ctx() => TurnContext(
      CancelToken(),
      input: const Input('probe', id: 'probe'),
      pinnedTools: const [],
      messages: const [],
      promptSections: [],
    );
