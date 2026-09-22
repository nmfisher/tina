import 'dart:io';

import '../runtime/plugin.dart';
import 'agent_pipeline.dart';

/// Prepended to every agent's identity under `--safe-mode`. The write/edit/bash
/// tools have already been removed from the registry; this is soft reinforcement
/// so the model does not waste a turn reaching for a tool that is not there.
const String _safeModePreamble = '''<safe-mode>
This is a READ-ONLY session. The file-writing tools (write, edit) and the
shell (bash) are NOT available to you — you cannot create, modify, or delete
files, and you cannot run commands. Investigate and answer using read-only
tools (read, grep, glob, search) and report your findings. If the task you are
given requires changing anything, stop and explain that the session is read-only
and the change cannot be made.
</safe-mode>
''';

/// One ordered segment of an assembled system prompt.
///
/// Prompt assembly is an ordered list of [PromptContributor]s joined by
/// [joinPromptContributors]. [defaultPromptContributors] builds the built-in
/// sections in their historical byte order; profiles can mount extra sections
/// with [promptContributorPlugin] and collect whatever a scope declares with
/// [promptContributorsFromScope].
///
/// [contribute] returns the section's raw block text — the separators around
/// it belong to the join, not to the section.
abstract class PromptContributor {
  /// Stable id of the section ('safe_mode', 'identity', 'environment',
  /// 'project_context' for the built-ins).
  String get id;

  /// The section's raw block text, without any surrounding separators.
  String contribute();
}

/// A [PromptContributor] whose text comes from a zero-argument builder,
/// evaluated when the section is asked to [PromptContributor.contribute].
class _Section implements PromptContributor {
  @override
  final String id;

  final String Function() _text;

  _Section(this.id, this._text);

  @override
  String contribute() => _text();
}

/// Base prompt sections, assembled before invocation middleware:
///
/// 1. `safe_mode` — the read-only preamble, only under `safeMode`; it glues
///    straight onto the identity.
/// 2. `identity` — the role-specific identity (override-or-main is resolved by
///    the caller; this list carries the final string).
/// 3. `environment` — the `<environment>` block: cwd/os/date lines, then the
///    repository summary appended when its source yields text.
/// Project instructions are supplied at request time by agent middleware.
///
/// The warm-load sources are read afresh on every call, and a throwing source
/// is treated as absent — one bad hook must never break every prompt build.
/// [loadProjectContext] false withholds the repository summary. Project files
/// are loaded separately by request middleware using the runtime trust context.
List<PromptContributor> defaultPromptContributors({
  required String identity,
  required PromptContext context,
  String? cwd,
  bool safeMode = false,
  bool? loadProjectContext,
  List<PromptContributor>? extraContributors,
}) {
  final resolvedCwd = cwd ?? context.projectRoot;
  final trusted = context.loadProjectContext && (loadProjectContext ?? true);
  final os = Platform.operatingSystem;
  final today = DateTime.now().toIso8601String().split('T').first;
  // The warm-load blocks, gated by the same trust flag as AGENTS.md. A
  // throwing source must never break every prompt build — treat it as
  // absent. The repository summary supplies factual orientation.
  String? repoSummary;
  if (trusted) {
    try {
      repoSummary = context.repoSummarySource?.call();
    } catch (_) {
      repoSummary = null;
    }
  }

  final environment = StringBuffer()
    ..writeln('cwd: $resolvedCwd')
    ..writeln('os: $os')
    ..write('date: $today');
  if (repoSummary != null && repoSummary.isNotEmpty) {
    environment
      ..writeln()
      ..write(repoSummary);
  }

  return [
    // Under --safe-mode the preamble leads the identity so the read-only
    // constraint is the first thing the model sees. It is concatenated
    // directly onto the identity, exactly as when it was built inline.
    if (safeMode) _Section('safe_mode', () => '$_safeModePreamble\n'),
    _Section('identity', () => identity),
    _Section(
        'environment',
        () => '<environment>\n'
            '$environment\n'
            '</environment>\n'),
    // Profile-mounted sections trail the built-ins (one blank line each),
    // in registration order — a mounted section can extend or contextualize
    // the shared blocks but never reorder or shadow them.
    ...?extraContributors,
  ];
}

/// Leading separator each built-in section gets when contributors are joined
/// into a prompt. This encodes today's layout, byte for byte — the segments
/// are *not* naively newline-joined: the safe-mode preamble glues straight
/// onto the identity, the `<environment>` block follows the identity after one
/// blank line, and the `<project-context>` block trails the environment after
/// a single newline. Sections with no entry here (extra sections mounted by
/// profiles) default to one blank line.
const Map<String, String> _sectionLead = <String, String>{
  'safe_mode': '',
  'identity': '',
  'environment': '\n\n',
  'project_context': '\n',
};

/// Joins [contributors] into the final prompt text, inserting the separators
/// the assembled prompt has always had ([_sectionLead]).
String joinPromptContributors(List<PromptContributor> contributors) {
  final buf = StringBuffer();
  for (final contributor in contributors) {
    buf
      ..write(_sectionLead[contributor.id] ?? '\n\n')
      ..write(contributor.contribute());
  }
  return buf.toString();
}

/// Assembles the base identity, environment and static plugin contributions.
/// Reading project instruction files belongs to request middleware.
String _buildAgentPrompt({
  required String identity,
  required PromptContext context,
  String? cwd,
  bool safeMode = false,
  bool? loadProjectContext,
  List<PromptContributor>? extraContributors,
}) =>
    joinPromptContributors(defaultPromptContributors(
      identity: identity,
      context: context,
      cwd: cwd,
      safeMode: safeMode,
      loadProjectContext: loadProjectContext,
      extraContributors: extraContributors,
    ));

/// Resolve the entry agent's full system prompt: the `[prompts.main]` override
/// from [overrides] when set (a non-empty string), else [pipeline.mainIdentity];
/// then wrapped with the shared environment and static prompt contributions.
///
/// When [workflowEnabled] is false the built-in identity is passed through
/// [stripWorkflowGuidance], so an agent with no `launch_workflow` tool is not
/// told to prefer launching one. A `[prompts.main]` override is the user's own
/// prose and is never rewritten.
///
/// This is the root identity the whole fleet descends from — a delegated
/// sub-agent inherits its parent's *resolved* prompt verbatim, so overriding
/// `main` here changes every agent that inherits it.
///
/// [loadProjectContext] gates the repository summary here. Agent middleware
/// receives the runtime PromptContext trust decision separately.
String resolveMainPrompt(
  AgentPipeline pipeline, {
  Map<String, String>? overrides,
  String? cwd,
  bool safeMode = false,
  bool? loadProjectContext,
  PluginScope? scope,
  bool workflowEnabled = true,
}) {
  final override = overrides?['main'];
  final identity = (override != null && override.isNotEmpty)
      ? override
      : (workflowEnabled
          ? pipeline.mainIdentity
          : stripWorkflowGuidance(pipeline.mainIdentity));
  return _buildAgentPrompt(
      identity: identity,
      context: pipeline.promptContext,
      cwd: cwd,
      safeMode: safeMode,
      loadProjectContext: loadProjectContext,
      extraContributors:
          scope == null ? null : promptContributorsFromScope(scope));
}

/// Resolve a system prompt from an explicit [identity] string (a node's
/// `system_prompt` attribute — tin-80ll), wrapped with the shared
/// environment and static prompt contributions. This is the node-run analogue
/// of [resolveMainPrompt]: where the entry agent's identity comes from
/// [AgentPipeline.mainIdentity], a node's identity comes from its DOT attribute.
///
/// Project file loading is deferred until middleware prepares a request.
String resolveIdentityPrompt(
  String identity, {
  PromptContext? context,
  String? cwd,
  bool safeMode = false,
  bool? loadProjectContext,
  PluginScope? scope,
}) =>
    _buildAgentPrompt(
        identity: identity,
        context: context ?? PromptContext(),
        cwd: cwd,
        safeMode: safeMode,
        loadProjectContext: loadProjectContext,
        extraContributors:
            scope == null ? null : promptContributorsFromScope(scope));

/// Typed identity of a prompt-contributor contribution in a [PluginScope].
/// The transport is the scope's contribution registry ([promptContributorPlugin]
/// registers under it, [promptContributorsFromScope] reads it back in
/// declared registration order); the key names the seam for profiles that
/// want to probe whether the scope carries prompt sections at all.
final ServiceKey<PromptContributor> promptContributorServiceKey =
    ServiceKey<PromptContributor>('tina.engine.prompt_contributor');

/// Every [PromptContributor] registered in [scope], in declared registration
/// order. Contributions of other kinds are ignored.
List<PromptContributor> promptContributorsFromScope(PluginScope scope) => [
      for (final contribution in scope.contributions)
        if (contribution.contribution is PromptContributor)
          contribution.contribution as PromptContributor,
    ];

/// Builds a one-contributor plugin: activating it registers [contributor]
/// under [id] in the active scope. Profiles mount extra prompt sections with
/// this — mounted sections are collected by [promptContributorsFromScope];
/// wiring them into the assembled prompt is the profile's business.
PluginDescriptor promptContributorPlugin(
        String id, PromptContributor contributor) =>
    PluginDescriptor(
      id: id,
      factory: FnPluginFactory((context) {
        context.register(contributor, id: id);
        return contributor;
      }),
    );
