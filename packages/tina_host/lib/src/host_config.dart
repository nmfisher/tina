/// The values a host decides up front: which provider to build, the model
/// label, the working directory, and the plugins to mount. A value object
/// — nothing here touches a store, a terminal, or tina's old config
/// format — and **no permission mode**: that concept belongs to the
/// enforcement boundary in `tina_tools`, and only its plugin-mounting
/// owner handles the value.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show AgentPlugin;
import 'session_questions.dart';
import 'snapshot_feature.dart';
import 'host.dart' show SessionOperation, SessionNotices;

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
    this.restoreModel = true,
    required this.workingDirectory,
    this.plugins = const [],
    this.systemPrompt = '',
    this.sessionTitle,
    this.details,
    this.questions,
    this.notices,
    this.snapshotFeatureFor,
    this.operationsFor,
    this.requestHistoryLimit = 256,
  });

  /// Builds the provider for **one** session. Called once per
  /// [Host.start]; two hosts from one config never share an instance.
  final ProviderFactory providerFactory;

  /// The model label, handed to the factory.
  final String model;
  final bool restoreModel;

  /// The directory the session works in.
  final String workingDirectory;

  /// The plugins to mount on the loop, in registration order. The tool
  /// set is just one of them; whatever permissions concept
  /// a session needs lives inside its plugin, never here.
  final List<AgentPlugin> plugins;

  /// The session's system prompt: a setting derive consults, restartable.
  /// Empty by default — the core owns no prompt text.
  final String systemPrompt;

  /// A human-facing title recorded with the session, when persisted.
  final String? sessionTitle;

  /// The session's counters — depth, children in flight, tokens spent —
  /// recorded with the session (registry row when persisted). Null
  /// means a fresh [SessionDetails] of zeros.
  final SessionDetails? details;

  /// Optional ordinary-question service supplied by application composition.
  /// Ownership transfers to this host; use a fresh instance for each session.
  final SessionQuestions? questions;

  /// Optional owner-side output, transferred to this host at startup.
  final SessionNotices? notices;

  /// Application adapters select public observations without teaching the host
  /// about concrete plugins. Called for startup and dynamically loaded plugins.
  final SnapshotFeature? Function(AgentPlugin)? snapshotFeatureFor;

  /// Owner-side operation handlers for startup and dynamically loaded plugins.
  final Map<String, SessionOperation> Function(AgentPlugin)? operationsFor;

  /// Maximum retained retry receipts, including active requests. At capacity,
  /// terminal receipts may expire; if all are active, new requests are refused.
  final int requestHistoryLimit;
}
