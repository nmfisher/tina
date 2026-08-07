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

/// Assembles a system prompt from a role-specific [identity] (the agent's
/// purpose and tool guidance) followed by the shared environment block and any
/// AGENTS.md project context discovered upward from [cwd]. [cwd] defaults to the
/// process cwd. Resolved fresh on each call so a new date or edited AGENTS.md
/// lands on the next resolution.
///
/// When [loadProjectContext] is false the AGENTS.md walk is skipped — used by
/// the project-trust gate to withhold an untrusted project's instructions from
/// the system prompt.
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

  // Under --safe-mode the preamble leads the identity so the read-only
  // constraint is the first thing the model sees.
  final base = '''
${safeMode ? '$_safeModePreamble\n' : ''}$identity

<environment>
cwd: $resolvedCwd
os: $os
date: $today
</environment>
''';

  if (agents.isEmpty) return base;
  return '$base\n${_renderAgentsBlock(agents)}';
}

/// Resolve the full system prompt for [role]: the override from [overrides]
/// when one is set for [role.name] (a non-empty string), else [role.promptIdentity];
/// then wrapped with the shared `<environment>` and `<project-context>` blocks.
///
/// [overrides] is typically [Config.promptOverrides]. An empty/absent entry
/// means "use the role's identity". The wrapper is always applied, so an
/// override only ever replaces the role's identity prose — never the environment
/// plumbing or AGENTS.md project context.
///
/// When [loadProjectContext] is false the `<project-context>` (AGENTS.md) block
/// is omitted — the project-trust gate's withholding of an untrusted project's
/// instructions.
String resolveSystemPrompt(
  AgentRole role, {
  Map<String, String>? overrides,
  String? cwd,
  bool safeMode = false,
  bool loadProjectContext = true,
}) {
  final override = overrides?[role.name];
  final identity = (override != null && override.isNotEmpty)
      ? override
      : role.promptIdentity;
  return _buildAgentPrompt(
      identity: identity, cwd: cwd, safeMode: safeMode, loadProjectContext: loadProjectContext);
}

/// Resolve a system prompt from an explicit [identity] string (a node's
/// `system_prompt` attribute — tin-80ll), wrapped with the shared
/// `<environment>` and `<project-context>` blocks. This is the node-run analogue
/// of [resolveSystemPrompt]: where a sub-agent's identity comes from an
/// [AgentRole], a node's identity comes from its DOT attribute.
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
