/// The pure verdict for a proposed working-context edit.
///
/// Both evaluation points — the mirror's `synchronize` at a model-call
/// boundary and a plugin's `replaceWorkingContext` (and, later, a dry run
/// at tool time) — ask the same question: given the current context, an
/// optional exported base, and a proposed message list, may the proposal
/// be adopted, and if not, which rule fired? This library answers it with
/// no file I/O, no loop state and no writes; the callers own persistence
/// and the log.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

import 'working_context.dart';

/// Why an edit was rejected. The mirror collapses all kinds into one
/// receipt; callers that rethrow keep their historic error types per kind.
enum ContextEditProblemKind {
  /// The proposal was authored against state that has since moved.
  stale,

  /// The message list violates provider-neutral structure (pairing, roles,
  /// empty messages) or signed-reasoning integrity.
  structural,

  /// The edit drops or rewrites content the loop protects: the current
  /// user request, or exchanges from a batch that has not settled.
  protected,
}

final class ContextEditProblem {
  const ContextEditProblem(this.kind, this.message);
  final ContextEditProblemKind kind;

  /// The exact message the pipeline threw before extraction, so callers
  /// rethrowing by kind preserve observable strings byte for byte.
  final String message;

  @override
  String toString() => message;
}

/// Facts about the in-flight turn an edit must respect. Between turns a
/// caller passes null and the in-turn rules do not apply.
final class ActiveTurnContext {
  const ActiveTurnContext({required this.turnId, required this.messages});
  final String turnId;
  final List<Message> messages;
}

sealed class ContextEditVerdict {
  const ContextEditVerdict();
}

/// The proposal equals the base: nothing to do, no snapshot, no receipt.
final class ContextEditUnchanged extends ContextEditVerdict {
  const ContextEditUnchanged();
}

final class ContextEditAccepted extends ContextEditVerdict {
  const ContextEditAccepted(this.merged);
  final List<Message> merged;
}

final class ContextEditRejectedVerdict extends ContextEditVerdict {
  const ContextEditRejectedVerdict(this.problem);
  final ContextEditProblem problem;
}

/// Evaluates a proposed working-context replacement against [current].
///
/// Rules, in firing order (mirroring the pre-extraction pipeline):
/// 1. With [base] (the exported context an editor read): an unchanged
///    proposal is [ContextEditUnchanged]; state that moved past the base
///    in a way the append rebase cannot honor is a stale rejection.
/// 2. The merged list (or, with no base, the proposal itself) must be
///    structurally valid (`validateContextMessages`) — structural.
/// 3. Every signed reasoning block must match its original text and
///    completeness by signature — structural.
/// 4. With [activeTurn]: the current user request must survive and every
///    outstanding tool call must have settled — protected.
///
/// The plugin's own counter check (`Stale working-context edit`) compares
/// the caller's expectation to `current` before calling; that remains the
/// caller's job because `current` here is ground truth by definition.
ContextEditVerdict evaluateContextEdit({
  required WorkingContext current,
  required List<Message> edited,
  WorkingContext? base,
  ActiveTurnContext? activeTurn,
}) {
  final proposal = base == null ? null : () {
    if (sameMessages(edited, base.messages)) return const ContextEditUnchanged();
    if (current.revision != base.revision ||
        current.throughSeq < base.throughSeq ||
        current.messages.length < base.messages.length ||
        !sameMessages(current.messages.take(base.messages.length), base.messages)) {
      return const ContextEditRejectedVerdict(
          ContextEditProblem(ContextEditProblemKind.stale, 'Stale context file'));
    }
    return null;
  }();
  if (proposal is ContextEditVerdict) return proposal;

  final merged = base == null
      ? edited
      : [...edited, ...current.messages.skip(base.messages.length)];  final frozen = freezeMessages(merged);
  try {
    validateContextMessages(frozen);
  } on FormatException catch (error) {
    return ContextEditRejectedVerdict(ContextEditProblem(
        ContextEditProblemKind.structural,
        error.message.isEmpty ? 'Invalid context message' : error.message));
  }
  // Provider signatures are opaque. Retain the exact signed block or drop
  // it; callers cannot fabricate or rewrite signed reasoning.
  final signed = <String, ReasoningBlock>{
    for (final m in current.messages)
      for (final r in m.reasoning)
        if (r.signature != null) r.signature!: r,
  };
  for (final m in frozen) {
    for (final r in m.reasoning) {
      if (r.signature == null) continue;
      final original = signed[r.signature];
      if (original == null ||
          original.text != r.text ||
          original.complete != r.complete) {
        return const ContextEditRejectedVerdict(ContextEditProblem(
            ContextEditProblemKind.structural,
            'Signed reasoning must remain intact'));
      }
    }
  }
  final turn = activeTurn;
  if (turn != null) {
    // The accepted user request stays intact, but settled tool exchanges
    // within this same turn can be rewritten or evicted. Outstanding calls
    // must settle before any replacement can be accepted.
    if (turn.messages.isNotEmpty &&
        !frozen.any((m) => sameMessages([m], [turn.messages.first]))) {
      return const ContextEditRejectedVerdict(ContextEditProblem(
          ContextEditProblemKind.protected,
          'The current user request must remain intact'));
    }
    final pending = <String>{};
    for (final m in turn.messages) {
      pending.addAll(m.content.whereType<ToolUseBlock>().map((b) => b.id));
      pending
          .removeAll(m.content.whereType<ToolResultBlock>().map((b) => b.toolUseId));
    }
    if (pending.isNotEmpty) {
      return const ContextEditRejectedVerdict(ContextEditProblem(
          ContextEditProblemKind.protected,
          'The executing tool batch must settle first'));
    }
  }
  return ContextEditAccepted(frozen);
}
