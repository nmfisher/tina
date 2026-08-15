import 'dart:io';

import 'package:path/path.dart' as p;

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

/// Supplies the `<project-environment>` block injected inside the shared
/// `<environment>` block — the warm-load seam for the environment record
/// (docs/proposals/environment_agent.md, "Warm load"). Set by the app at
/// composition to read the repo's `ENVIRONMENT.md` + tracking entry; null (the
/// default) omits the block. The same [loadProjectContext] flag that withholds
/// an untrusted project's `AGENTS.md` withholds this block, so a cloned repo's
/// environment claims never reach the prompt untrusted.
///
/// Mutable and process-global by design, mirroring `defaultPipeline` and the
/// shared tool singletons: set once at composition, read per prompt build. The
/// closure must not throw (a read failure returns null, not an error).
String? Function()? projectEnvironmentSource;

/// Assembles a system prompt from a role-specific [identity] (the agent's
/// purpose and tool guidance) followed by the shared environment block and any
/// AGENTS.md project context discovered upward from [cwd]. [cwd] defaults to the
/// process cwd. Resolved fresh on each call so a new date or edited AGENTS.md
/// lands on the next resolution.
///
/// When [loadProjectContext] is false the AGENTS.md walk is skipped — used by
/// the project-trust gate to withhold an untrusted project's instructions from
/// the system prompt. The `<project-environment>` block is gated the same way.
String _buildAgentPrompt({
  required String identity,
  String? cwd,
  bool safeMode = false,
  bool loadProjectContext = true,
}) {
  final resolvedCwd = cwd ?? Directory.current.path;
  final os = Platform.operatingSystem;
  final today = DateTime.now().toIso8601String().split('T').first;
  final agents = loadProjectContext
      ? _loadAgentsFiles(resolvedCwd)
      : const <({String path, String content})>[];

  // The warm-load block, gated by the same trust flag as AGENTS.md. A throwing
  // source must never break every prompt build — treat it as absent.
  String? projectEnv;
  if (loadProjectContext) {
    try {
      projectEnv = projectEnvironmentSource?.call();
    } catch (_) {
      projectEnv = null;
    }
  }

  final environment = StringBuffer()
    ..writeln('cwd: $resolvedCwd')
    ..writeln('os: $os')
    ..write('date: $today');
  if (projectEnv != null && projectEnv.isNotEmpty) {
    environment
      ..writeln()
      ..write(projectEnv);
  }

  // Under --safe-mode the preamble leads the identity so the read-only
  // constraint is the first thing the model sees.
  final base =
      '${safeMode ? '$_safeModePreamble\n' : ''}$identity\n\n<environment>\n'
      '$environment\n</environment>\n';

  if (agents.isEmpty) return base;
  return '$base\n${_renderAgentsBlock(agents)}';
}

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
  bool loadProjectContext = true,
}) {
  final override = overrides?['main'];
  final identity =
      (override != null && override.isNotEmpty) ? override : pipeline.mainIdentity;
  return _buildAgentPrompt(
      identity: identity,
      cwd: cwd,
      safeMode: safeMode,
      loadProjectContext: loadProjectContext);
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
  String? cwd,
  bool safeMode = false,
  bool loadProjectContext = true,
}) =>
    _buildAgentPrompt(
        identity: identity,
        cwd: cwd,
        safeMode: safeMode,
        loadProjectContext: loadProjectContext);

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
