import 'dart:io';

import 'package:path/path.dart' as p;

import '../runtime/plugin.dart';
import 'agent_pipeline.dart';

/// Hard cap per file. Anyone who needs more than this is using AGENTS.md
/// wrong; we still rather truncate than balloon every request.
const int _agentsFileByteCap = 50 * 1024;

/// And a cap on the total combined size across all AGENTS.md files found.
const int _agentsTotalByteCap = 200 * 1024;

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

/// The built-in prompt sections, in the exact byte order the assembled prompt
/// has always had:
///
/// 1. `safe_mode` — the read-only preamble, only under `safeMode`; it glues
///    straight onto the identity.
/// 2. `identity` — the role-specific identity (override-or-main is resolved by
///    the caller; this list carries the final string).
/// 3. `environment` — the `<environment>` block: cwd/os/date lines, then the
///    repo summary and project-environment records appended inside the block
///    when their sources yield text.
/// 4. `project_context` — the `<project-context>` AGENTS.md block, only when
///    the (trust-gated) walk found at least one file.
///
/// The warm-load sources are read afresh on every call, and a throwing source
/// is treated as absent — one bad hook must never break every prompt build.
/// [loadProjectContext] false withholds the AGENTS.md walk *and* the warm-load
/// blocks: an untrusted project contributes nothing.
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
  final agents = trusted
      ? _loadAgentsFiles(resolvedCwd)
      : const <({String path, String content})>[];

  // The warm-load blocks, gated by the same trust flag as AGENTS.md. A
  // throwing source must never break every prompt build — treat it as
  // absent. The repo summary leads (cheap factual orientation); the
  // environment record follows (measured setup/test baseline).
  String? repoSummary;
  String? projectEnv;
  if (trusted) {
    try {
      repoSummary = context.repoSummarySource?.call();
    } catch (_) {
      repoSummary = null;
    }
    try {
      projectEnv = context.projectEnvironmentSource?.call();
    } catch (_) {
      projectEnv = null;
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
  if (projectEnv != null && projectEnv.isNotEmpty) {
    environment
      ..writeln()
      ..write(projectEnv);
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
    if (agents.isNotEmpty)
      _Section('project_context', () => _renderAgentsBlock(agents)),
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

/// Assembles a system prompt from a role-specific [identity] (the agent's
/// purpose and tool guidance) followed by the shared environment block and any
/// AGENTS.md project context discovered upward from [cwd]. [cwd] defaults to the
/// runtime project root. Resolved fresh on each call so a new date or edited AGENTS.md
/// lands on the next resolution.
///
/// When [loadProjectContext] is false the AGENTS.md walk is skipped — used by
/// the project-trust gate to withhold an untrusted project's instructions from
/// the system prompt. The `<project-environment>` block is gated the same way.
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
/// then wrapped with the shared `<environment>` and `<project-context>` blocks.
///
/// This is the root identity the whole fleet descends from — a delegated
/// sub-agent inherits its parent's *resolved* prompt verbatim, so overriding
/// `main` here changes every agent that inherits it.
///
/// When [loadProjectContext] is false the `<project-context>` (AGENTS.md) block
/// is omitted — the project-trust gate's withholding of an untrusted project's
/// instructions.
String resolveMainPrompt(
  AgentPipeline pipeline, {
  Map<String, String>? overrides,
  String? cwd,
  bool safeMode = false,
  bool? loadProjectContext,
  PluginScope? scope,
}) {
  final override = overrides?['main'];
  final identity = (override != null && override.isNotEmpty)
      ? override
      : pipeline.mainIdentity;
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
/// `<environment>` and `<project-context>` blocks. This is the node-run analogue
/// of [resolveMainPrompt]: where the entry agent's identity comes from
/// [AgentPipeline.mainIdentity], a node's identity comes from its DOT attribute.
///
/// When [loadProjectContext] is false the `<project-context>` (AGENTS.md) block
/// is omitted.
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

/// Walk from [startDir] up to filesystem root, collecting every AGENTS.md
/// along the way. Returned root-first → cwd-last so the most specific rules
/// land at the bottom of the system prompt (where instruction-following is
/// strongest). Read failures and oversize files are skipped, not raised.
List<({String path, String content})> _loadAgentsFiles(String startDir) {
  final out = <({String path, String content})>[];
  var totalBytes = 0;
  var dir = Directory(startDir).absolute;
  while (true) {
    final candidate = File(p.join(dir.path, 'AGENTS.md'));
    if (candidate.existsSync()) {
      try {
        var content = candidate.readAsStringSync();
        if (content.length > _agentsFileByteCap) {
          content =
              '${content.substring(0, _agentsFileByteCap)}\n… (truncated)\n';
        }
        if (totalBytes + content.length <= _agentsTotalByteCap) {
          out.insert(0, (path: candidate.path, content: content));
          totalBytes += content.length;
        }
      } on FileSystemException {
        // Skip unreadable files; one bad AGENTS.md shouldn't poison the
        // whole walk.
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return out;
}

String _renderAgentsBlock(List<({String path, String content})> agents) {
  final buf = StringBuffer()
    ..writeln('<project-context>')
    ..writeln(
        'Project-specific instructions discovered in AGENTS.md files. The '
        'innermost file (closest to cwd) overrides outer ones on conflict.');
  for (final a in agents) {
    buf
      ..writeln()
      ..writeln('--- ${a.path} ---')
      ..writeln(a.content.trimRight());
  }
  buf.writeln('</project-context>');
  return buf.toString();
}
