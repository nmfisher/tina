/// The build-then-reload orchestration, shared by every surface that
/// triggers a local plugin build — the TUI's `/plugins build` command
/// and the engine's agent-facing `plugin_build` tool (one
/// implementation, two surfaces; commit 24 built the TUI half, commit
/// 25 added the tool half). Deliberately free of `dart:io` so the wasm
/// engine's plugin can import it: every filesystem and process touch
/// lives behind the injected seams.
///
/// The sequence:
///
/// 1. compile the source dir (the [PluginBuildFlow.buildArtifact] seam;
///    failures throw [PluginBuildException] with a clean, user-facing
///    message — missing toolchain, compiler error, absent entry point);
/// 2. local-trust consent, keyed by artifact hash ([LocalConsentBook]) —
///    first install of a hash prompts, the same hash does not, a changed
///    hash re-prompts; declining installs nothing and the previous
///    artifact stays;
/// 3. on consent (or an already-consented hash) the artifact is already
///    in the cache with origin `local` (the seam did the install);
/// 4. when a plugin is attached, offer the reload (a NEW component
///    instance — in-instance state not written through the artifact's
///    persistence is lost) with the notice saying so; detached builds
///    install without reloading. No watcher, no polling.
library;

/// A clean, user-facing build failure: what is missing and what to do,
/// never a stack trace.
final class PluginBuildException implements Exception {
  const PluginBuildException(this.message, {this.stderr});
  final String message;
  final String? stderr;

  @override
  String toString() =>
      stderr == null || stderr!.trim().isEmpty
          ? message
          : '$message\ncompiler output:\n$stderr';
}

/// A successful local build: what was installed and where.
final class LocalPluginBuild {
  const LocalPluginBuild({
    required this.name,
    required this.version,
    required this.hash,
    required this.componentPath,
    required this.builtAt,
  });

  final String name;

  /// `local-<hash prefix>`: one version per artifact content.
  final String version;

  /// The artifact's sha256 — the consent key.
  final String hash;
  final String componentPath;
  final DateTime builtAt;
}

/// Local-trust consent, keyed by artifact hash: consent once per build,
/// re-prompt on hash change. The file-backed book
/// (`LocalPluginConsent` in `build.dart`) is the native
/// implementation; the interface keeps this file free of `dart:io` for
/// the wasm engine's tool surface.
abstract interface class LocalConsentBook {
  /// Whether this artifact hash still needs an explicit consent.
  bool needsConsent(String hash);

  /// Records the consent for [hash].
  void remember(String hash);
}

/// What one [PluginBuildFlow.run] produced, for callers that report the
/// outcome as data (the agent tool result) instead of only notices.
final class PluginBuildReport {
  const PluginBuildReport({
    this.build,
    this.failure,
    this.consentDeclined = false,
    this.attached = false,
    this.reloaded = false,
  });

  /// The installed artifact, when the build succeeded.
  final LocalPluginBuild? build;

  /// The clean failure message when the build failed.
  final String? failure;

  /// The consent prompt was answered No: nothing was installed and the
  /// previous artifact stays attached.
  final bool consentDeclined;

  /// Whether a plugin was attached when the build completed.
  final bool attached;

  /// Whether the reload ran (only meaningful with [attached]).
  final bool reloaded;

  /// Whether an artifact was installed.
  bool get built => build != null;
}

/// The build-then-reload orchestration over injected seams, separated
/// from every surface so the consent/reload/notice semantics are
/// testable without a TUI and callable from the engine's tool path.
final class PluginBuildFlow {
  PluginBuildFlow({
    required this.buildArtifact,
    required this.consent,
    required this.prompt,
    required this.notice,
    required this.reload,
    required this.attached,
  });

  /// Compiles + installs; returns the build, or throws
  /// [PluginBuildException] with a clean, user-facing message.
  final Future<LocalPluginBuild> Function(String sourcePath) buildArtifact;

  /// The hash-keyed local consent book.
  final LocalConsentBook consent;

  /// The consent prompt for a new artifact hash.
  final Future<bool> Function(LocalPluginBuild build) prompt;

  /// Status lines for the transcript.
  final void Function(String text) notice;

  /// Offers the reload (only called when [attached]).
  final Future<void> Function() reload;

  /// Whether a plugin is currently attached to the session.
  final bool Function() attached;

  Future<PluginBuildReport> run(String sourcePath) async {
    final LocalPluginBuild build;
    try {
      build = await buildArtifact(sourcePath);
    } on PluginBuildException catch (error) {
      notice('plugins build failed: $error');
      return PluginBuildReport(failure: '$error');
    }

    if (consent.needsConsent(build.hash)) {
      final approved = await prompt(build);
      if (!approved) {
        notice('plugins build: consent declined — the previous artifact '
            'stays attached and nothing was installed');
        return PluginBuildReport(build: build, consentDeclined: true);
      }
      consent.remember(build.hash);
    }

    notice('plugins build: ${build.name} ${build.version} installed '
        '(origin local, hash ${build.hash.substring(0, 12)}…)');

    if (!attached()) {
      notice('plugin not attached: the artifact is installed and mounts on '
          'the next session (or /plugins reload when one is)');
      return PluginBuildReport(build: build, attached: false);
    }
    notice('reloading the plugin: a reload is a NEW component instance — '
        'in-instance state not written through the artifact\'s persistence '
        'is lost');
    await reload();
    return PluginBuildReport(build: build, attached: true, reloaded: true);
  }
}
