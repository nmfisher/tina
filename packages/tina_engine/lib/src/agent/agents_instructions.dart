import 'dart:io';

import 'package:path/path.dart' as p;

import '../runtime/plugin.dart';
import 'agent_middleware.dart';
import 'instructions.dart';

/// Default instruction policy. No loader is special-cased in the agent loop.
PluginDescriptor agentsInstructionsPlugin() => PluginDescriptor(
      id: 'tina.engine.agents-instructions',
      factory: FnPluginFactory((context) {
        final middleware = AgentsInstructions(context.scope);
        context.register(middleware);
        return middleware;
      }),
    );

/// Refreshes applicable AGENTS.md files before ordinary model requests, while
/// leaving compaction prompts alone. A custom profile may omit or replace it.
class AgentsInstructions extends AgentMiddleware {
  final PluginScope? scope;
  AgentsInstructions([this.scope]);
  @override
  String get id => 'tina.engine.agents-instructions';
  @override
  String get name => 'Project instructions';
  @override
  Future<AgentDecision<AgentRequest>> beforeRequest(
      AgentContext context, AgentRequest request) async {
    if (!context.loadWorkspaceContext || context.stage == AgentStage.compact) {
      return AgentDecision.next(request);
    }
    final loaded = await loadAgentsInstructions(context);
    context.check();
    if (scope != null) notifyInstructions(scope!, loaded);
    return AgentDecision.next(loaded.instructions.isEmpty
        ? request
        : request.copyWith(
            system:
                '${request.system}\n${renderAgentsInstructions(loaded.instructions)}'));
  }
}

/// Hard cap per file. Anyone who needs more than this is using AGENTS.md
/// wrong; we still rather truncate than balloon every request.
const int _agentsFileByteCap = 50 * 1024;

/// And a cap on the total combined size across all AGENTS.md files found.
const int _agentsTotalByteCap = 200 * 1024;

/// Walk from [startDir] up to filesystem root, collecting every AGENTS.md
/// along the way. Returned root-first → cwd-last so the most specific rules
/// land at the bottom of the system prompt (where instruction-following is
/// strongest). Read failures and oversize files are skipped, not raised.
Future<InstructionLoad> loadAgentsInstructions(AgentContext context) async {
  context.check();
  final startDir = context.cwd;
  if (!context.loadWorkspaceContext) {
    return InstructionLoad(InstructionKind.agents, const [], cwd: startDir);
  }
  final out = <Instruction>[];
  var totalBytes = 0;
  var complete = true;
  var dir = Directory(startDir).absolute;
  while (true) {
    context.check();
    final candidate = File(p.join(dir.path, 'AGENTS.md'));
    if (await candidate.exists()) {
      try {
        final sourceText = await candidate.readAsString();
        var content = sourceText;
        if (content.length > _agentsFileByteCap) {
          complete = false;
          content =
              '${content.substring(0, _agentsFileByteCap)}\n… (truncated)\n';
        }
        if (totalBytes + content.length <= _agentsTotalByteCap) {
          out.insert(
              0,
              Instruction(
                id: candidate.uri.toString(),
                kind: InstructionKind.agents,
                source: candidate.uri,
                scope: dir.uri,
                text: content,
                sourceText: sourceText,
                complete: sourceText.length <= _agentsFileByteCap,
              ));
          totalBytes += content.length;
        } else {
          complete = false;
        }
      } on FileSystemException {
        complete = false;
        // Skip unreadable files; one bad AGENTS.md shouldn't poison the
        // whole walk.
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return InstructionLoad(InstructionKind.agents, out,
      cwd: startDir, complete: complete);
}

String renderAgentsInstructions(List<Instruction> agents) {
  final buf = StringBuffer()
    ..writeln('<project-context>')
    ..writeln(
        'Project-specific instructions discovered in AGENTS.md files. The '
        'innermost file (closest to cwd) overrides outer ones on conflict.');
  for (final a in agents) {
    buf
      ..writeln()
      ..writeln('--- ${a.source!.toFilePath()} ---')
      ..writeln(a.text.trimRight());
  }
  buf.writeln('</project-context>');
  return buf.toString();
}
