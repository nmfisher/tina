/// The build-then-reload flow semantics (owner-approved
/// toolchain-present path): consent keyed by hash, auto-reload only
/// when attached, notices, and the detached/install-only branch —
/// all with a stubbed compiler, no real toolchain.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_plugin_registry/tina_plugin_registry.dart';

import 'package:tina/src/plugin_build_flow.dart';

void main() {
  late Directory root;
  late File consentFile;
  late LocalPluginConsent consent;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-flow-');
    consentFile = File('${root.path}/local-consent.json');
    consent = LocalPluginConsent(file: consentFile);
  });
  tearDown(() => root.deleteSync(recursive: true));

  LocalPluginBuild buildOf(String hash) => LocalPluginBuild(
        name: 'my-plugin',
        version: 'local-${hash.substring(0, 12)}',
        hash: hash,
        componentPath: '${root.path}/component.wasm',
        builtAt: DateTime.utc(2026, 12, 1),
      );

  test('first build prompts and consents; reload offered when attached',
      () async {
    final hash = 'a' * 64;
    var prompted = 0;
    final notices = <String>[];
    final reloads = <String>[];
    var built = false;
    final flow = PluginBuildFlow(
      buildArtifact: (dir) async {
        built = true;
        return buildOf(hash);
      },
      consent: consent,
      prompt: (build) async {
        prompted++;
        return true;
      },
      notice: notices.add,
      reload: () async => reloads.add('reload'),
      attached: () => true,
    );

    await flow.run('${root.path}/src');

    expect(built, isTrue);
    expect(prompted, 1);
    expect(consent.needsConsent(hash), isFalse,
        reason: 'the consent is remembered');
    final text = notices.join('\n');
    expect(text, contains('origin local'));
    expect(text, contains('NEW component instance'));
    expect(reloads, ['reload'], reason: 'attached: the reload is offered');
  });

  test('the same hash does not re-prompt; a changed hash re-prompts',
      () async {
    final prompts = <String>[];

    Future<void> runOnce(String hash) async {
      final flow = PluginBuildFlow(
        buildArtifact: (dir) async => buildOf(hash),
        consent: consent,
        prompt: (build) async {
          prompts.add(build.hash);
          return true;
        },
        notice: (_) {},
        reload: () async {},
        attached: () => false,
      );
      await flow.run('${root.path}/src');
    }

    await runOnce('c' * 64);
    await runOnce('c' * 64);
    expect(prompts, hasLength(1),
        reason: 'the same hash consented once, not again');
    await runOnce('d' * 64);
    expect(prompts, hasLength(2), reason: 'a changed hash re-prompts');
  });

  test('decline installs nothing further: no consent recorded, no reload',
      () async {
    final hash = 'e' * 64;
    final notices = <String>[];
    final reloads = <String>[];
    final flow = PluginBuildFlow(
      buildArtifact: (dir) async => buildOf(hash),
      consent: consent,
      prompt: (build) async => false,
      notice: notices.add,
      reload: () async => reloads.add('reload'),
      attached: () => true,
    );

    await flow.run('${root.path}/src');

    expect(consent.needsConsent(hash), isTrue,
        reason: 'a declined build is not consented');
    final text = notices.join('\n');
    expect(text, contains('consent declined'));
    expect(text, contains('previous artifact stays'));
    expect(reloads, isEmpty,
        reason: 'the old artifact stays attached: no reload');
  });

  test('build while detached installs but does not reload', () async {
    final notices = <String>[];
    final reloads = <String>[];
    final flow = PluginBuildFlow(
      buildArtifact: (dir) async => buildOf('f' * 64),
      consent: consent,
      prompt: (build) async => true,
      notice: notices.add,
      reload: () async => reloads.add('reload'),
      attached: () => false,
    );

    await flow.run('${root.path}/src');

    expect(reloads, isEmpty);
    expect(notices.join('\n'), contains('plugin not attached'));
    expect(notices.join('\n'), contains('origin local'),
        reason: 'the install still happened');
  });

  test('a failed build stops before consent, prompt or reload', () async {
    final notices = <String>[];
    var prompted = false;
    final flow = PluginBuildFlow(
      buildArtifact: (dir) async => null,
      consent: consent,
      prompt: (build) async {
        prompted = true;
        return true;
      },
      notice: notices.add,
      reload: () async => fail('never reached'),
      attached: () => true,
    );

    await flow.run('${root.path}/src');

    expect(prompted, isFalse);
    expect(notices, isEmpty,
        reason: 'the caller noticed the failure before returning null');
  });
}
