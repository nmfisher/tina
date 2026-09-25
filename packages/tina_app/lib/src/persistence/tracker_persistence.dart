import 'package:logging/logging.dart';
import 'package:tina_app/src/goals/goal_store.dart';
import 'package:tina_app/src/plans/plan_store.dart';
import 'package:tina_engine/tina_engine.dart';

final _log = Logger('tina.persist.trackers');

/// Binds the [GoalStore] and [PlanStore] to a [SessionStore] so `/goal` and
/// `/plan` state survives `/resume`.
///
/// Two directions:
///
/// * **persist** — [install] hooks both stores' mutations. Every goal/plan
///   change re-writes BOTH tracker blobs for that conversation through
///   [SessionStore.updateConversationTrackers] (the engine method takes both
///   fields; null clears one while the other survives). Before the write the
///   binder runs the host-supplied `ensureRegisteredFor` callback: a goal can
///   be set before the conversation's first message, when it exists in no
///   manifest yet. Writes are serialized on an internal chain so rapid
///   mutations apply in order, and are best-effort — a failure is logged and
///   swallowed (the in-memory state is unaffected), mirroring the spend
///   ledger's `_flushUsage`.
///
/// * **hydrate** — [hydrate] restores one conversation from its persisted
///   [ConversationMeta]; [hydrateAll] restores a whole manifest at startup.
///   The manifest is authoritative: a null blob clears whatever the stores
///   hold (stale in-memory state from an earlier session in the same
///   process), while hydration itself never writes back.
///
/// Conversation ids are the app's dispatch key everywhere: hydrate is keyed
/// by the conversation id the live stores use (the startup manifest's ids, or
/// the active conversation's id on an in-session `/resume`, which can differ
/// from the manifest's under legacy re-keying).
class TrackerPersistence {
  TrackerPersistence({
    required this.goalStore,
    required this.planStore,
    required this.store,
  });

  final GoalStore goalStore;
  final PlanStore planStore;
  final SessionStore store;

  String? Function(String conversationId)? _sessionIdFor;
  Future<void> Function(String conversationId)? _ensureRegisteredFor;
  Future<void> _pending = Future.value();
  var _installed = false;

  /// Hook both stores' mutation paths into the manifest. Idempotent — a
  /// second install keeps the first callbacks.
  ///
  /// [sessionIdFor] resolves the session a conversation belongs to (null →
  /// skip: unknown/closed conversation). [ensureRegisteredFor] makes sure the
  /// conversation exists on disk BEFORE the write, so a tracker set ahead of
  /// the transcript's first append still lands in a manifest the next
  /// `--resume` can see. Both callbacks must not throw (a throw is logged by
  /// the persist loop and drops that write, like any other failure).
  void install({
    required String? Function(String conversationId) sessionIdFor,
    required Future<void> Function(String conversationId) ensureRegisteredFor,
  }) {
    if (_installed) return;
    _installed = true;
    _sessionIdFor = sessionIdFor;
    _ensureRegisteredFor = ensureRegisteredFor;
    goalStore.persistHook = _onChanged;
    planStore.persistHook = _onChanged;
  }

  /// Restore one conversation's trackers from its persisted [meta].
  /// [conversationId] keys the stores and defaults to the meta's own id;
  /// pass it explicitly on an in-session resume, where the live conversation
  /// id can differ from the manifest's (legacy re-key). Never throws.
  void hydrate(ConversationMeta? meta, {String? conversationId}) {
    final cid = conversationId ?? meta?.id;
    if (cid == null) return;
    try {
      goalStore.hydrate(cid, meta?.goal);
    } catch (e, st) {
      _log.warning('goal hydrate failed for $cid', e, st);
    }
    try {
      planStore.hydrate(cid, meta?.plan);
    } catch (e, st) {
      _log.warning('plan hydrate failed for $cid', e, st);
    }
  }

  /// Restore every conversation of a startup manifest (fresh sessions pass an
  /// empty iterable — a no-op). Never throws.
  void hydrateAll(Iterable<ConversationMeta> metas) {
    for (final meta in metas) {
      hydrate(meta);
    }
  }

  /// Persist the conversation's CURRENT tracker state now, without waiting
  /// for a mutation — used to capture changes made before [install] (the
  /// headless command-dispatch window). Skips when both trackers are empty:
  /// a run with nothing to persist must not force-register a fresh session.
  void persistIfPresent(String conversationId) {
    final hasGoal = !goalStore.read(conversationId).isEmpty;
    final hasPlan = !planStore.read(conversationId).isEmpty;
    if (!hasGoal && !hasPlan) return;
    _onChanged(conversationId);
  }

  /// Wait for every scheduled write to settle (shutdown, tests).
  Future<void> flush() => _pending;

  /// Detach the hooks (only if they are still this binder's). A disposed
  /// controller must stop writing into stores a later owner may have
  /// re-bound.
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (goalStore.persistHook == _onChanged) goalStore.persistHook = null;
    if (planStore.persistHook == _onChanged) planStore.persistHook = null;
    _sessionIdFor = null;
    _ensureRegisteredFor = null;
  }

  void _onChanged(String conversationId) {
    _pending = _pending.then((_) => _persist(conversationId));
  }

  Future<void> _persist(String conversationId) async {
    final ensure = _ensureRegisteredFor;
    final sidFor = _sessionIdFor;
    if (ensure == null || sidFor == null) return;
    try {
      // Register first: a goal set ahead of the transcript's first write
      // exists in no manifest yet, and updateConversationTrackers would
      // StateError on the unknown conversation.
      await ensure(conversationId);
      final sid = sidFor(conversationId);
      if (sid == null || sid.isEmpty) return;
      await store.updateConversationTrackers(
        sid,
        conversationId,
        goal: _goalJson(conversationId),
        plan: _planJson(conversationId),
      );
    } catch (e, st) {
      // Best-effort: the in-memory trackers are unaffected, and the next
      // mutation retries (the chain never breaks — _persist never throws).
      _log.warning('tracker persist failed for $conversationId', e, st);
    }
  }

  Map<String, dynamic>? _goalJson(String conversationId) {
    final goal = goalStore.read(conversationId);
    return goal.isEmpty ? null : goal.toJson();
  }

  Map<String, dynamic>? _planJson(String conversationId) {
    final plan = planStore.read(conversationId);
    return plan.isEmpty ? null : plan.toJson();
  }
}
