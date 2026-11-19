import 'package:tina_settings/tina_settings.dart';

/// One leg of a model profile: a provider+model pair. The provider may be
/// omitted — the leg then inherits the session's provider (the active
/// profile's main-leg provider).
final class ModelLeg {
  const ModelLeg({this.provider, required this.model});

  /// Null (or empty) inherits the session's provider.
  final String? provider;
  final String model;

  /// The leg as a `provider/model` reference. A bare model keeps the
  /// session provider's prefix when one is named, mirroring how the
  /// `[default] model` line reads.
  String reference(String? sessionProvider) => provider == null ||
          provider!.isEmpty
      ? (sessionProvider == null || sessionProvider.isEmpty
          ? model
          : '$sessionProvider/$model')
      : '$provider/$model';

  @override
  bool operator ==(Object other) =>
      other is ModelLeg &&
      other.provider == provider &&
      other.model == model;

  @override
  int get hashCode => Object.hash(provider, model);
}

/// The three legs a profile bundles. The conversation (`main`), the model
/// `launch_subagent` children use (`subagent`), and the shared permission
/// classifier / command-pattern suggester model (`approver`).
enum ProfileLeg { main, subagent, approver }

/// A named bundle of model legs — a preset, not live state. Switching to a
/// profile copies its legs into the current values; the legs are the truth.
final class ModelProfile {
  const ModelProfile(
      {required this.name, this.main, this.subagent, this.approver});

  final String name;
  final ModelLeg? main;
  final ModelLeg? subagent;
  final ModelLeg? approver;

  ModelLeg? leg(ProfileLeg which) => switch (which) {
        ProfileLeg.main => main,
        ProfileLeg.subagent => subagent,
        ProfileLeg.approver => approver,
      };

  /// The leg as a `provider/model` reference, or null when the profile
  /// omits it. Omitted legs are NOT inherited from main: each leg follows
  /// its own fallback (subagent → the parent's current model at spawn,
  /// approver → the legacy classifier chain). Only the PROVIDER is
  /// inherited, from [sessionProvider].
  String? legReference(ProfileLeg which, {String? sessionProvider}) =>
      leg(which)?.reference(sessionProvider);
}

/// The active profile's name as a session-scoped setting, so a `/profile`
/// switch survives resume like a `/model` switch does.
final activeProfileSetting = SettingDefinition<String>(
  id: 'tina/providers/profile',
  label: 'Active model profile',
  description:
      'The named profile this conversation runs under. Empty follows the '
      'config file\'s profile. Switching copies the profile\'s model legs '
      'into this conversation; the config file keeps the presets.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

/// The main conversation model as a `provider/model` reference. Empty
/// follows the active profile's main leg (or the config's default model).
final profileMainModelSetting = SettingDefinition<String>(
  id: 'tina/providers/main_model',
  label: 'Main model (conversation override)',
  description:
      'A per-conversation override of the active profile\'s main leg, as a '
      'provider/model reference. The profiles themselves are edited in '
      'Settings → Models → Model profiles (the table, written to the config '
      'file); this session override is what /model changes and it dies with '
      'the conversation. '
      '"anthropic/claude-sonnet-4". Empty follows the active profile\'s '
      'main leg. /model overrides it for this conversation without '
      'changing the profile.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

/// The subagent leg. Empty follows the active profile; a profile without a
/// subagent leg keeps the long-standing behavior of children inheriting
/// the parent's current model and provider at spawn.
final profileSubagentModelSetting = SettingDefinition<String>(
  id: 'tina/providers/subagent_model',
  label: 'Subagent model (conversation override)',
  description:
      'A per-conversation override of the active profile\'s subagent leg: '
      'the model launch_subagent children use, as a provider/model '
      'reference. Profiles are edited in Settings → Models → Model '
      'profiles (the table, written to the config file); '
      'reference. Empty follows the active profile\'s subagent leg; when '
      'neither is set, children inherit the parent\'s current model at '
      'spawn. Running children keep the model they started with.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

/// The approver leg: one model for BOTH judgment consumers — the
/// permission classifier and the command-pattern suggester.
final profileApproverModelSetting = SettingDefinition<String>(
  id: 'tina/providers/approver_model',
  label: 'Approver model (conversation override)',
  description:
      'A per-conversation override of the active profile\'s approver leg: '
      'the model for auto-approval judgments and command-pattern '
      'suggestions. Profiles are edited in Settings → Models → Model '
      'profiles (the table, written to the config file); '
      'suggestions, as a provider/model reference. Empty follows the '
      'active profile\'s approver leg, then the legacy classifier model, '
      'then this conversation\'s model. The provider must support '
      'structured output.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

/// The profile module's settings, registered on the providers plugin.
final profileSettings = <SettingDefinition<Object>>[
  activeProfileSetting,
  profileMainModelSetting,
  profileSubagentModelSetting,
  profileApproverModelSetting,
];

/// The classifier instruction, consolidated into the profiles module with
/// the approver leg it tunes. Same id and storage path as when it lived in
/// tina_mode, so stored values read unchanged.
final classifierInstructionSetting = SettingDefinition<String>(
  id: 'tina/mode/classifier_instruction',
  label: 'Auto-approval classifier instruction',
  description:
      'Optional additional permission preferences. Blank uses the built-in '
      'approval policy. Your preferences are prepended to every classification '
      'request; session overrides are saved with this conversation. Approvals '
      'and the OS sandbox still enforce execution permissions.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

/// The DEPRECATED classifier model override. Superseded by the approver
/// leg (profile or `tina/providers/approver_model`); honored for one
/// release as the last override before the conversation model, then
/// removed. No longer presented as the way to pick the judge model.
final classifierModelSetting = SettingDefinition<String>(
  id: 'tina/mode/classifier_model',
  label: 'Auto-approval classifier model (deprecated)',
  description:
      'DEPRECATED: superseded by a profile\'s approver leg or the Approver '
      'model setting; honored for one more release, then removed. When set, '
      'it overrides the conversation model for auto-approval judgments, for '
      'example "anthropic/claude-haiku".',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

/// The classifier timeout, consolidated into the profiles module. Same id
/// and storage path as when it lived in tina_mode.
final classifierTimeoutSetting = SettingDefinition<int>(
  id: 'tina/mode/classifier_timeout_seconds',
  label: 'Auto-approval classifier timeout (seconds)',
  description:
      'Maximum time for each permission classification request, including its '
      'retry. Positive whole seconds; changes apply to the next request.',
  defaultValue: 60,
  kind: SettingKind.integer,
  minimum: 1,
  applyAt: ApplyAt.nextRequest,
);

/// The classifier settings that moved from tina_mode into the profiles
/// module — registered on the tina/mode plugin so their ids, storage
/// paths and settings section stay put for the release they live
/// through.
final classifierSettings = <SettingDefinition<Object>>[
  classifierInstructionSetting,
  classifierModelSetting,
  classifierTimeoutSetting,
];

/// The profile this run is under: an explicit launch profile (`--profile`)
/// wins for the run without being persisted; otherwise a profile switched
/// in this conversation (session scope, restored on resume); otherwise the
/// config file's `profile` key.
String effectiveProfileName({
  String? launchProfile,
  ScopedSettings? settings,
  required String configProfile,
}) {
  if (launchProfile != null && launchProfile.isNotEmpty) return launchProfile;
  final saved = (settings?.read(activeProfileSetting).value ?? '').trim();
  if (saved.isNotEmpty) return saved;
  return configProfile;
}

/// A leg's effective value: the current leg setting first (the legs are
/// the truth), then the active profile's leg, then null for the caller's
/// leg-specific fallback.
String? effectiveProfileLeg(
  SettingDefinition<String> legSetting,
  ScopedSettings? settings,
  ModelProfile? profile,
  ProfileLeg which, {
  String? sessionProvider,
}) {
  final current = (settings?.read(legSetting).value ?? '').trim();
  if (current.isNotEmpty) return current;
  return profile?.legReference(which, sessionProvider: sessionProvider);
}
