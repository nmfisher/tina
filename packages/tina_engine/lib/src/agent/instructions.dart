import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

import '../runtime/plugin.dart';

/// Open source category: plugins can declare their own namespaced kinds.
final class InstructionKind {
  final String name;
  const InstructionKind(this.name) : assert(name != '');
  static const agents = InstructionKind('agents');
  static const skill = InstructionKind('skill');
  @override
  bool operator ==(Object other) =>
      other is InstructionKind && name == other.name;
  @override
  int get hashCode => name.hashCode;
}

/// The exact text admitted by a loader, with provenance independent of prompts.
/// A revision identifies the full source text, even when [text] was truncated.
/// Scope describes applicability; it grants no filesystem or tool permission.
final class Instruction {
  final String id;
  final InstructionKind kind;
  final Uri? source;
  final Uri? scope;
  final String text;
  final String revision;
  final bool complete;

  Instruction({
    required this.id,
    required this.kind,
    required this.text,
    required String sourceText,
    this.source,
    this.scope,
    this.complete = true,
  }) : revision = sha256.convert(utf8.encode(sourceText)).toString();

  InstructionRef get ref => InstructionRef(id, revision);
}

/// Persist this reference rather than copying instruction bodies into rules.
final class InstructionRef {
  final String id;
  final String revision;
  const InstructionRef(this.id, this.revision);

  bool matches(Instruction instruction) =>
      id == instruction.id && revision == instruction.revision;
}

/// AGENTS loads are snapshots (including empty ones) for [cwd]. Skill loads
/// contain only the successfully loaded body; listing skills emits no event.
final class InstructionLoad {
  final InstructionKind kind;
  final String? cwd;
  final List<Instruction> instructions;

  /// False when any source was omitted, unreadable or truncated.
  final bool complete;
  InstructionLoad(this.kind, Iterable<Instruction> instructions,
      {this.cwd, this.complete = true})
      : instructions = List.unmodifiable(instructions);
}

/// Register with PluginContext.register. Keep callbacks short: schedule any
/// analysis as a cancellable Invocation owned by the plugin, never inline.
/// Events may repeat; use instruction identity/revision to deduplicate work.
abstract interface class InstructionObserver {
  void onInstructionsLoaded(InstructionLoad load);
}

/// Publish only text already admitted by the loader's trust/access checks.
/// Parent observers can see child loads. Removed/disposed observers cannot.
/// Observation failure must not prevent the original instructions loading.
void notifyInstructions(PluginScope scope, InstructionLoad load) {
  if (!scope.isAdmitting) return;
  for (PluginScope? current = scope;
      current != null;
      current = current.parent) {
    if (!current.isAdmitting) continue;
    for (final entry in current.contributions.toList()) {
      if (!scope.isAdmitting || !current.isAdmitting) return;
      final observer = entry.contribution;
      if (observer is! InstructionObserver ||
          !current.contributions.contains(entry)) continue;
      try {
        observer.onInstructionsLoaded(load);
      } catch (_) {
        // Do not log instruction text or provider exception contents.
        Logger('tina.instructions').warning('Instruction observer failed');
      }
    }
  }
}
