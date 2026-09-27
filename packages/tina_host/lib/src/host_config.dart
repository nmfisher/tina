/// The values a host decides up front: which provider to build, the model
/// label, the working directory, and the session mode. A value object —
/// nothing here touches a store, a terminal, or tina's old config format.
library;

import 'dart:io';

import 'package:tina_core/tina_core.dart';
import 'package:tina_tools/tina_tools.dart' show PermissionMode;

/// Builds one provider. Called **once per session, by that session's
/// host** — never store a shared instance: a provider owns its connection
/// and a shared one gets closed twice (the old engine is explicit about
/// this). The factory receives the config's [HostConfig.model] so the
/// model lives in one place.
typedef ProviderFactory = LlmProvider Function(String model);

/// Everything [Host.start] needs. Small and explicit on purpose: a daemon
/// later reads these from its own CLI or file; this package only defines
/// the shape.
final class HostConfig {
  const HostConfig({
    required this.providerFactory,
    this.model = 'scripted',
    required this.workingDirectory,
    this.mode = PermissionMode.normal,
    this.tinaDir,
  });

  /// Builds the provider for **one** session. Called once per
  /// [Host.start]; two hosts from one config never share an instance.
  final ProviderFactory providerFactory;

  /// The model label, handed to the factory.
  final String model;

  /// The directory the session works in: the sandbox's project root and
  /// the root the file tools resolve relative paths against.
  final String workingDirectory;

  /// The mode the session starts in. Consulted **per call** afterwards —
  /// switching it mid-session takes effect on the next call, and this
  /// starting value is not baked into anything but the sandbox's initial
  /// state.
  final PermissionMode mode;

  /// The Tina data tree the sandbox denies. Defaults to the real
  /// `~/.tina`; tests pass a temp directory.
  final Directory? tinaDir;

  /// The Tina data dir for a session: [tinaDir] or `~/.tina`.
  Directory get effectiveTinaDir =>
      tinaDir ?? Directory('${Platform.environment['HOME'] ?? '/tmp'}/.tina');
}
