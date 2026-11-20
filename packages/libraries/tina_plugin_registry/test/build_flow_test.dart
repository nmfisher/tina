/// The build-then-reload flow semantics (owner-approved
/// toolchain-present path), shared by the TUI command and the agent
/// tool: consent keyed by hash, auto-reload only when attached,
/// notices, the detached/install-only branch and the structured
/// [PluginBuildReport] the tool result reports — all with stubbed
/// compilers, no real toolchain.
library;

import 'package:test/test.dart';
import 'package:tina_plugin_registry/tina_plugin_registry.dart';

/// In-memory consent book: the hash-keyed semantics without a file.
final class _MemoryConsent implements LocalConsentBook {
  final remembered = <String>{};

  @override
  bool needsConsent(String hash) => !remembered.contains(hash);

  @override
  void remember(String hash) => remembered.add(hash);
}

void main() {
  _MemoryConsent consentBook() => _MemoryConsent();

  LocalPluginBuild buildOf(String hash) => LocalPluginBuild(
        name: 'my-plugin',
        version: 'local-${hash.substring(0, 12)}',
        hash: hash,
        componentPath: '/cache/my-plugin/component.wasm',
        builtAt: DateTime.utc(2026, 12, 1),
      );

  test('first build prompts and consents; reload offered when attached',
      () async {
    final hash = 'a' * 64;
    final consent = consentBook();
    var prompted = 0;
    final notices = <String>[];
    final reloads = <String>[];
    var built = false;
    final flow = PluginBuildFlow(
      buildArtifact: (sourcePath) async {
        built = true;
        expect(sourcePath, '/src/my-plugin');
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

    final report = await flow.run('/src/my-plugin');

    expect(built, isTrue);
    expect(prompted, 1);
    expect(consent.needsConsent(hash), isFalse,
        reason: 'the consent is remembered');
    expect(report.built, isTrue);
    expect(report.build!.hash, hash);
    expect(report.attached, isTrue);
    expect(report.reloaded, isTrue, reason: 'attached: the reload is offered');
    expect(report.failure, isNull);
    final text = notices.join('\n');
    expect(text, contains('origin local'));
    expect(text, contains('NEW component instance'));
    expect(reloads, ['reload']);
  });

  test('the same hash does not re-prompt; a changed hash re-prompts',
      () async {
    final consent = consentBook();
    final prompts = <String>[];

    Future<PluginBuildReport> runOnce(String hash) async {
      final flow = PluginBuildFlow(
        buildArtifact: (sourcePath) async => buildOf(hash),
        consent: consent,
        prompt: (build) async {
          prompts.add(build.hash);
          return true;
        },
        notice: (_) {},
        reload: () async {},
        attached: () => false,
      );
      return flow.run('/src/my-plugin');
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
    final consent = consentBook();
    final notices = <String>[];
    final reloads = <String>[];
    final flow = PluginBuildFlow(
      buildArtifact: (sourcePath) async => buildOf(hash),
      consent: consent,
      prompt: (build) async => false,
      notice: notices.add,
      reload: () async => reloads.add('reload'),
      attached: () => true,
    );

    final report = await flow.run('/src/my-plugin');

    expect(report.consentDeclined, isTrue);
    expect(report.reloaded, isFalse);
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
      buildArtifact: (sourcePath) async => buildOf('f' * 64),
      consent: consentBook(),
      prompt: (build) async => true,
      notice: notices.add,
      reload: () async => reloads.add('reload'),
      attached: () => false,
    );

    final report = await flow.run('/src/my-plugin');

    expect(report.built, isTrue);
    expect(report.attached, isFalse);
    expect(report.reloaded, isFalse);
    expect(reloads, isEmpty);
    expect(notices.join('\n'), contains('plugin not attached'));
    expect(notices.join('\n'), contains('origin local'),
        reason: 'the install still happened');
  });

  test('a failed build stops before consent, prompt or reload', () async {
    final notices = <String>[];
    var prompted = false;
    final flow = PluginBuildFlow(
      buildArtifact: (sourcePath) async =>
          throw const PluginBuildException('no Dart SDK found on PATH'),
      consent: consentBook(),
      prompt: (build) async {
        prompted = true;
        return true;
      },
      notice: notices.add,
      reload: () async => fail('never reached'),
      attached: () => true,
    );

    final report = await flow.run('/src/my-plugin');

    expect(report.built, isFalse);
    expect(report.failure, contains('no Dart SDK found on PATH'));
    expect(prompted, isFalse);
    expect(notices.single, contains('plugins build failed'));
    expect(notices.single, contains('no Dart SDK found on PATH'));
  });

  test('a compiler failure carries its stderr through the report',
      () async {
    final flow = PluginBuildFlow(
      buildArtifact: (sourcePath) async => throw const PluginBuildException(
          'plugin compilation failed (exit 1)',
          stderr: 'Error: cannot resolve bin/main.dart'),
      consent: consentBook(),
      prompt: (build) async => true,
      notice: (_) {},
      reload: () async {},
      attached: () => true,
    );

    final report = await flow.run('/src/my-plugin');

    expect(report.failure, contains('plugin compilation failed'));
    expect(report.failure, contains('compiler output'));
    expect(report.failure, contains('Error: cannot resolve bin/main.dart'));
  });
}
