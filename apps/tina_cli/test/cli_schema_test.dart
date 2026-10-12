import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/src/cli_options.dart';
import 'package:tina/src/cli_schema.dart';
import 'package:tina/src/plugin_catalog.dart';
import 'package:tina/src/shell_completion.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_goals/tina_goals.dart';
import 'package:tina_providers/tina_providers.dart';

void main() {
  test(
    'extension flags are parsed and documented without building plugins',
    () {
      var builds = 0;
      const option = CliOption(
        'review-format',
        abbreviation: 'r',
        description: 'Reviewer\'s format [name]: selected safely.',
        choices: ['short', 'long'],
      );
      final registry = firstPartyPlugins()
        ..register(
          'acme/review',
          (_) {
            builds++;
            throw StateError('metadata must not construct a plugin');
          },
          description: 'Review',
          cli: const PluginCli(options: [option]),
        );
      final schema = applicationCliSchema(registry: registry);
      expect(schema.parse(['--review-format', 'short'])[option], 'short');
      expect(schema.parse(['-r', 'long'])[option], 'long');
      expect(schema.help, contains('--review-format, -r'));
      expect(schema.help, contains('acme/review:'));
      for (final shell in ['bash', 'zsh', 'fish']) {
        expect(
          shellCompletion(shell, schema: schema),
          contains('review-format'),
        );
      }
      expect(builds, 0);
    },
  );

  test(
    'required and optional values, aliases, equals and stdin are distinct',
    () {
      final schema = applicationCliSchema();
      final args = schema.parse([
        '--models',
        '--resume=id',
        '--goal',
        '-',
        '-c',
      ]);
      expect(args.contains(modelsOption), true);
      expect(args[modelsOption], isNull);
      expect(args[resumeOption], 'id');
      expect(args[goalOption], '-');
      expect(args.contains(continueOption), true);
      expect(schema.parse(['--models', 'local'])[modelsOption], 'local');
      expect(
        schema.parse(['--goal=--leading-dashes'])[goalOption],
        '--leading-dashes',
      );
      for (final input in [
        ['--config', '--help'],
        ['--goal'],
        ['--help=true'],
        ['--backend=unknown'],
        ['--unknown'],
        ['positional'],
      ]) {
        expect(
          () => schema.parse(input),
          throwsFormatException,
          reason: '$input',
        );
      }
      expect(() => schema.parse(['--max-goal-turns=0']), throwsFormatException);
      expect(
        () => schema.validate(schema.parse(['--max-goal-turns=2'])),
        throwsFormatException,
      );
    },
  );

  test('colliding flags and aliases identify both owners before startup', () {
    const first = CliOption('first', abbreviation: 'x', description: 'First');
    for (final second in [
      const CliOption('first', description: 'Duplicate'),
      const CliOption(
        'second',
        abbreviation: 'x',
        description: 'Alias collision',
      ),
    ]) {
      expect(
        () => CliSchema(
          bootstrap: [first],
          plugins: {
            'acme/second': PluginCli(options: [second]),
          },
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'owners',
            allOf(contains('application'), contains('acme/second')),
          ),
        ),
      );
      expect(
        () => CliSchema(
          bootstrap: [],
          plugins: {
            'acme/first': const PluginCli(options: [first]),
            'acme/second': PluginCli(options: [second]),
          },
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'owners',
            allOf(contains('acme/first'), contains('acme/second')),
          ),
        ),
      );
    }
  });

  test('headless command selection is generic and rejects two commands', () {
    const review = CliOption(
      'review',
      description: 'Review',
      value: CliValue.none,
    );
    final registry = firstPartyPlugins()
      ..register(
        'acme/review',
        (_) => throw StateError('not built'),
        description: 'Review',
        cli: PluginCli(
          options: [review],
          sessionCommand: (args) => args.contains(review)
              ? CliSessionCommand(option: review, run: (_, _) async => 0)
              : null,
        ),
      );
    final schema = applicationCliSchema(registry: registry);
    final selected = schema.sessionCommand(schema.parse(['--review']));
    expect(selected!.owner, 'acme/review');
    expect(selected.command.option, same(review));
    expect(
      () =>
          schema.sessionCommand(schema.parse(['--review', '--goal', 'do it'])),
      throwsFormatException,
    );
  });

  test(
    'bash completion executes choices and preserves paths with spaces',
    () async {
      final schema = applicationCliSchema();
      final script = shellCompletion('bash', schema: schema);
      final directory = Directory.systemTemp.createTempSync('cli-completion-');
      addTearDown(() => directory.deleteSync(recursive: true));
      Directory('${directory.path}/a workspace').createSync();
      File('${directory.path}/a file').writeAsStringSync('');
      Future<List<String>> complete(String previous, String current) async {
        final result = await Process.run('bash', [
          '-c',
          '$script\n${r'''
COMP_WORDS=(tina "$1" "$2")
COMP_CWORD=2
_tina_complete
if ((${#COMPREPLY[@]})); then printf '%s\n' "${COMPREPLY[@]}"; fi
'''}',
          'completion-test',
          previous,
          current,
        ], workingDirectory: directory.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return (result.stdout as String).trimRight().split('\n');
      }

      expect(await complete('--backend', 'a'), ['auto', 'ansi']);
      expect(await complete('--cwd', 'a'), ['a workspace']);
      expect(
        await complete('--config', 'a'),
        unorderedEquals(['a workspace', 'a file']),
      );
      expect(await complete('--resume', '--go'), ['--goal']);
      expect(await complete('--goal', '--go'), ['']);
    },
    skip: Platform.isWindows,
  );

  test(
    'zsh specs preserve optional values and safely quote descriptions',
    () async {
      const custom = CliOption(
        'custom',
        description: 'Owner\'s [format]: \$(touch should-not-run)',
        choices: ['one', 'two'],
      );
      final script = shellCompletion(
        'zsh',
        schema: CliSchema(bootstrap: [custom, resumeOption]),
      );
      final result = await Process.run('zsh', [
        '-f',
        '-c',
        r'''
compdef() { :; }
_arguments() { printf '%s\n' "$@"; }
''' +
            script +
            '\n_tina',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('--resume['));
      expect(result.stdout, contains('::ID:'));
      expect(
        result.stdout,
        contains(r"Owner's \[format\]\: $(touch should-not-run)"),
      );
    },
    skip: !Platform.isMacOS,
  );
}
