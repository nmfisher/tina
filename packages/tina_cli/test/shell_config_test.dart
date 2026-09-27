// Config parsing: the same file and shape tina writes today
// (`version = 1`, a `[default]` section), the missing file, and files
// that cannot be honored. Pure and offline — one temp file per case.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_cli/tina_cli.dart';
import 'package:tina_llm/tina_llm.dart';

/// Writes [text] to a temp file and returns its path.
Future<String> writeConfig(String text) async {
  final dir = await Directory.systemTemp.createTemp('tina_cli_cfg_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/config')..writeAsStringSync(text);
  return file.path;
}

/// Two descriptors standing in for the built-ins: one openai-compatible,
/// one not, so provider lookup is observable without the real catalogue.
const testDescriptors = [
  ProviderDescriptor(
      id: 'provA',
      name: 'Provider A',
      wire: ProviderWire.openAiCompatible,
      baseUrl: 'https://a.example/v1',
      keyEnvVar: 'A_KEY',
      keyStyle: ProviderKeyStyle.bearer,
      models: {}),
  ProviderDescriptor(
      id: 'provB',
      name: 'Provider B',
      wire: ProviderWire.anthropic,
      baseUrl: 'https://b.example',
      keyEnvVar: 'B_KEY',
      keyStyle: ProviderKeyStyle.header,
      models: {}),
];

void main() {
  group('the config file tina writes today', () {
    test('version, bare model: rides the anthropic wire', () async {
      // The exact bytes this container ships.
      final path = await writeConfig('version = 1\n'
          '\n'
          '[default]\n'
          'model = "glm-5.3-flashx"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<ShellConfigOk>());
      expect(result.config.providerId, isNull,
          reason: 'no provider named — the anthropic wire is implied');
      expect(result.config.model, 'glm-5.3-flashx');
      expect(shellModelReference(result.config), 'glm-5.3-flashx');
      expect((result as ShellConfigOk).note, contains('glm-5.3-flashx'));
    });

    test('provider and model: both kept', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result.config.providerId, 'provA');
      expect(result.config.model, 'qwen-3');
      expect(shellModelReference(result.config), 'provA/qwen-3');
    });

    test('a provider/model reference in the model wins over the section',
        () async {
      final path = await writeConfig('[default]\n'
          'provider = "provA"\n'
          'model = "provB/model-x"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result.config.providerId, 'provB');
      expect(result.config.model, 'model-x');
    });

    test('comments and blank lines are skipped; literal strings read',
        () async {
      final path = await writeConfig('# Schema version — leave at 1.\n'
          'version = 1\n'
          '\n'
          "[default]\n"
          "provider = 'provB'\n"
          'model = "a \\"quoted\\" name"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result.config.providerId, 'provB');
      expect(result.config.model, 'a "quoted" name');
    });
  });

  group('problems keep the shell alive on defaults', () {
    test('a missing file is a success with the default model', () {
      final result = loadShellConfig(
          path: '/nonexistent/tina/config',
          descriptors: testDescriptors);
      expect(result, isA<ShellConfigOk>());
      expect((result as ShellConfigOk).path, isNull);
      expect(result.config.model, kShellDefaultModel);
      expect(result.config.providerId, isNull);
      expect(result.note, isNull, reason: 'nothing was read, nothing to note');
    });

    test('a file with no default model', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<ShellConfigProblem>());
      final problem = result as ShellConfigProblem;
      expect(problem.problem, contains('no [default] model'));
      expect(problem.config.model, kShellDefaultModel,
          reason: 'the shell still runs, on the fallback');
      expect(problem.note, contains('falling back'));
    });

    test('an empty file has no [default] section', () async {
      final path = await writeConfig('');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<ShellConfigProblem>());
      expect((result as ShellConfigProblem).problem,
          contains('no [default] section'));
    });

    test('a future version is refused, not guessed at', () async {
      final path = await writeConfig('version = 2\n'
          '[default]\n'
          'model = "m"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<ShellConfigProblem>());
      expect((result as ShellConfigProblem).problem, contains('version 2'));
    });

    test('bad syntax is refused whole', () async {
      final path = await writeConfig('version 1\n'
          '[default]\n'
          'model = "m"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<ShellConfigProblem>());
      expect((result as ShellConfigProblem).problem,
          contains('not valid config syntax'));
    });

    test('an unknown provider is refused with the model kept', () async {
      final path = await writeConfig('[default]\n'
          'provider = "nosuch"\n'
          'model = "m"\n');
      final result = loadShellConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<ShellConfigProblem>());
      final problem = result as ShellConfigProblem;
      expect(problem.problem, contains('unknown provider "nosuch"'));
      expect(problem.config.model, 'm',
          reason: 'the model string itself is still usable');
    });
  });

  test('the built-in descriptors resolve a real provider id', () {
    expect(descriptorByIdFor('glm', builtinDescriptors), isNotNull);
    expect(descriptorByIdFor('nope', builtinDescriptors), isNull);
  });
}
