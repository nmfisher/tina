import 'dart:io';

import 'package:tina_plugin_registry/tina_plugin_registry.dart';

/// The build-then-reload orchestration, separated from the console so
/// the consent/reload/notice semantics are testable without a TUI:
///
/// 1. compile the source dir (injectable compiler);
/// 2. local-trust consent, keyed by artifact hash — first install of a
///    hash prompts, the same hash does not, a changed hash re-prompts;
///    declining installs nothing and the previous artifact stays;
/// 3. on consent (or an already-consented hash), the artifact is
///    already in the cache with origin `local`;
/// 4. when a plugin is attached, offer the reload (a NEW component
///    instance — in-instance state not written through the artifact's
///    persistence is lost) with the notice saying so; detached builds
///    install without reloading. No watcher, no polling.
final class PluginBuildFlow {
  PluginBuildFlow({
    required this.buildArtifact,
    required this.consent,
    required this.prompt,
    required this.notice,
    required this.reload,
    required this.attached,
  });

  /// Compiles + installs; returns the build, or null after noticing a
  /// clean failure.
  final Future<LocalPluginBuild?> Function(Directory source) buildArtifact;

  /// The hash-keyed local consent book.
  final LocalPluginConsent consent;

  /// The consent prompt for a new artifact hash.
  final Future<bool> Function(LocalPluginBuild build) prompt;

  /// Status lines for the transcript.
  final void Function(String text) notice;

  /// Offers the reload (only called when [attached]).
  final Future<void> Function() reload;

  /// Whether a plugin is currently attached to the session.
  final bool Function() attached;

  Future<void> run(String sourcePath) async {
    final build = await buildArtifact(Directory(sourcePath));
    if (build == null) return;

    if (consent.needsConsent(build.hash)) {
      final approved = await prompt(build);
      if (!approved) {
        notice('plugins build: consent declined — the previous artifact '
            'stays attached and nothing was installed');
        return;
      }
      consent.remember(build.hash);
    }

    notice('plugins build: ${build.name} ${build.version} installed '
        '(origin local, hash ${build.hash.substring(0, 12)}…)');

    if (!attached()) {
      notice('plugin not attached: the artifact is installed and mounts on '
          'the next session (or /plugins reload when one is)');
      return;
    }
    notice('reloading the plugin: a reload is a NEW component instance — '
        'in-instance state not written through the artifact\'s persistence '
        'is lost');
    await reload();
  }
}
