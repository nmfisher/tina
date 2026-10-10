import 'package:tina_core/tina_core.dart';

/// The position range a [CompactedEntry] addresses: derived-message
/// positions [from]..[to] inclusive (as [AgentLoop.derive] counts them)
/// replaced by one summary text. A value type — the loop's compaction
/// request, handed to every [MessageProjection] before anything is
/// appended.
typedef MessageSplice = ({int from, int to, String summary});

/// One who owns a projection of the message history — a view the provider
/// request is actually built from, the working context today — may serve
/// a compaction itself instead of letting the loop splice the log.
///
/// The engine never names a plugin. [AgentLoop.compact] consults the
/// registered plugins that implement this interface, in registration
/// order, and stops at the first whose [applyCompaction] returns true;
/// when none does (none registered — today's default — or all decline)
/// the loop appends the [CompactedEntry] exactly as it always has. The
/// compaction-compose proposal later fills in the accepting branch.
///
/// Contract, and the reason it is phrased as accept-or-throw with
/// decline reserved for non-owners:
///
/// - A projection that DOES own the view the next request is built from
///   must never return false. A declined splice falls through to a
///   [CompactedEntry] — positions over the core derive — which a
///   projection-owned view (snapshot + tail) cannot replay: derivation
///   refuses a compaction that follows a working-context edit. Owning
///   means handling every splice: rewrite and snapshot, or throw.
/// - Throwing propagates out of [AgentLoop.compact] with nothing
///   appended. A half-served splice must not be papered over by the
///   loop's entry; the host asked for one compaction, not two divergent
///   histories.
/// - The loop validates the splice against the core derive BEFORE any
///   projection runs, so both branches start from the same precondition.
///   A projection whose list has diverged (context edits shrink or grow
///   it) throws on a splice its own index space cannot express.
abstract interface class MessageProjection {
  /// Serve [splice] against this projection: rewrite the projected
  /// messages and durably record the result, then return true. Return
  /// false to decline — see the class contract for who may. Throwing
  /// rejects the compaction with nothing appended to the log.
  bool applyCompaction(MessageSplice splice);
}
