// Model profiles: the config surface (`profile` + `[profiles.*]`), the
// legacy-config migration (a config without profiles synthesizes
// `default` from the `[default] provider`/`model` lines — nothing nags),
// and per-leg wire validation that names the profile and leg.
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina_providers/tina_providers.dart';

import 'assembly_config_test.dart' show testDescriptors, writeConfig;

void main() {
  group('legacy configs migrate silently', () {
    test('no profiles table synthesizes default from provider+model',
        () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect(result, isA<TinaConfigOk>());
      expect(result.config.profile, 'default');
      expect(result.config.profiles.keys, ['default']);
      final leg = result.config.activeProfile.main!;
      expect(leg.provider, 'provA');
      expect(leg.model, 'qwen-3');
      expect(result.config.mainModelReference, 'provA/qwen-3');
    });

    test('bare model on the anthropic wire keeps the implied provider',
        () async {
      final path = await writeConfig(
          'version = 1\n[default]\nmodel = "glm-5.3-flashx"\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect(result.config.mainModelReference, 'anthropic/glm-5.3-flashx');
    });

    test('the banner note is unchanged for a legacy config', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect((result as TinaConfigOk).note, contains('provA/qwen-3'));
      expect(result.note, isNot(contains('profile')),
          reason: 'a legacy config must not nag');
    });

    test('the banner note names a non-default active profile', () async {
      final path = await writeConfig('version = 1\n'
          'profile = "budget"\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n'
          '\n'
          '[profiles]\n'
          'budget = "provB/model-x"\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect((result as TinaConfigOk).note,
          allOf(contains('provB/model-x'), contains('profile budget')));
    });

    test('a missing config file synthesizes the scripted default', () {
      final result = loadTinaConfig(
          path: '/nonexistent/tina/config', descriptors: testDescriptors);
      expect(result.config.profile, 'default');
      expect(result.config.mainModelReference, 'anthropic/scripted');
    });

    test('the profiles-table flag distinguishes authored from synthesized',
        () async {
      final legacy = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n');
      expect(loadTinaConfig(path: legacy, descriptors: testDescriptors)
          .config
          .profilesTable, isFalse,
          reason: 'legacy configs keep their quiet model surface');
      final authored = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n'
          '\n'
          '[profiles]\n'
          'budget = "provB/model-x"\n');
      expect(loadTinaConfig(path: authored, descriptors: testDescriptors)
          .config
          .profilesTable, isTrue);
    });
  });

  group('the profiles table', () {
    test('three legs, provider+model pairs', () async {
      final path = await writeConfig('version = 1\n'
          'profile = "work"\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n'
          '\n'
          '[profiles.work]\n'
          'main = "provA/qwen-3"\n'
          '[profiles.work.subagent]\n'
          'provider = "provB"\n'
          'model = "model-x"\n'
          '[profiles.work.approver]\n'
          'model = "haiku-3"\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect(result.config.profile, 'work');
      final profile = result.config.activeProfile;
      expect(profile.legReference(ProfileLeg.main), 'provA/qwen-3');
      expect(profile.legReference(ProfileLeg.subagent), 'provB/model-x');
      // An omitted provider inherits the session's provider.
      expect(
          profile.legReference(ProfileLeg.approver,
              sessionProvider: result.config.providerId),
          'provA/haiku-3');
      expect(result.config.mainModelReference, 'provA/qwen-3');
    });

    test('one-line profiles are valid', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'provider = "provA"\n'
          'model = "qwen-3"\n'
          '\n'
          '[profiles]\n'
          'budget = "provB/model-x"\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect(result.config.profiles.keys, containsAll(['default', 'budget']));
      expect(result.config.profiles['budget']!.main!.provider, 'provB');
      expect(result.config.profiles['budget']!.subagent, isNull,
          reason: 'omitted legs are not inherited from main');
      expect(result.config.profiles['budget']!.approver, isNull);
    });

    test('judge is the deprecated spelling of approver', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'legacy = { judge = "provA/haiku-3" }\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect(result.config.profiles['legacy']!.approver!.model, 'haiku-3');
      expect(result.config.profiles['legacy']!.approver!.provider, 'provA');
    });

    test('an explicit approver wins over judge', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'both = { judge = "provA/old", approver = "provB/new" }\n');
      final result = loadTinaConfig(path: path, descriptors: testDescriptors);
      expect(result.config.profiles['both']!.approver!.provider, 'provB');
    });

    test('an unknown active profile is a load failure that names it',
        () async {
      final path = await writeConfig('version = 1\n'
          'profile = "ghost"\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'work = "provA/qwen-3"\n');
      expect(
          () => loadTinaConfig(path: path, descriptors: testDescriptors),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('"ghost"'))));
    });
  });

  group('per-leg wire validation names the profile and leg', () {
    test('an unknown provider in a leg', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'budget = { subagent = "nope/glm-5.3" }\n');
      expect(
          () => loadTinaConfig(path: path, descriptors: testDescriptors),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('budget'), contains('subagent'), contains('nope')))));
    });

    test('an empty model in a leg', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'budget = { main = "" }\n');
      expect(
          () => loadTinaConfig(path: path, descriptors: testDescriptors),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('budget'), contains('main')))));
    });

    test('an unknown leg key', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'odd = { judgey = "provA/x" }\n');
      expect(
          () => loadTinaConfig(path: path, descriptors: testDescriptors),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('judgey'))));
    });

    test('a leg table with foreign keys', () async {
      final path = await writeConfig('version = 1\n'
          '[default]\n'
          'model = "glm-5.3"\n'
          '\n'
          '[profiles]\n'
          'odd = { main = { provider = "provA", model = "x", bogus = 1 } }\n');
      expect(
          () => loadTinaConfig(path: path, descriptors: testDescriptors),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('provider and model'))));
    });

    test('the profiles table itself must be a table', () async {
      final path = await writeConfig(
          'version = 1\nprofiles = "nope"\n[default]\nmodel = "x"\n');
      expect(
          () => loadTinaConfig(path: path, descriptors: testDescriptors),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('[profiles]'))));
    });
  });

  group('ModelProfile reference resolution', () {
    test('a leg without provider inherits the session provider', () {
      const profile = ModelProfile(
          name: 'work',
          main: ModelLeg(provider: 'provA', model: 'qwen-3'),
          subagent: ModelLeg(model: 'glm-5.3'));
      expect(profile.legReference(ProfileLeg.main), 'provA/qwen-3');
      expect(profile.legReference(ProfileLeg.subagent,
          sessionProvider: 'provA'), 'provA/glm-5.3');
      expect(profile.legReference(ProfileLeg.subagent), 'glm-5.3',
          reason: 'no session provider: a bare model stays bare');
      expect(profile.legReference(ProfileLeg.approver), isNull);
    });
  });
}
