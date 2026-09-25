import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_session_store.dart';

/// The app→manifest direction of goal/plan persistence: [TrackerPersistence]
/// hooks the stores' mutations into `updateConversationTrackers` (both blobs
/// always written, ensureRegistered first, best-effort) and hydrates the
/// stores from a persisted [ConversationMeta] without writing back.
void main() {
  group('TrackerPersistence', () {
    late MemorySessionStore store;
    late GoalStore goals;
    late PlanStore plans;
    late TrackerPersistence binder;
    late String sid;
    late String cid;

    /// Records the binder's resolve order: the session lookup must run only
    /// AFTER ensureRegistered (which can mint the session id on first write).
    late List<String> order;

    setUp(() async {
      store = MemorySessionStore();
      sid = await store.createSession(providerId: 'anthropic');
      cid = await store.createConversation(sid);
      goals = GoalStore();
      plans = PlanStore();
      order = <String>[];
      binder = TrackerPersistence(
        goalStore: goals,
        planStore: plans,
        store: store,
      )..install(
          sessionIdFor: (id) {
            order.add('sid');
            return sid;
          },
          ensureRegisteredFor: (id) async {
            order.add('ensure');
          },
        );
      order.clear();
    });

    tearDown(() {
      goals.dispose();
      plans.dispose();
    });

    test('a goal mutation persists BOTH blobs, ensureRegistered first',
        () async {
      goals.set(cid, 'ship it');
      await binder.flush();
      final meta = store.metaFor(sid, cid)!;
      expect(meta.goal!['text'], 'ship it');
      expect(meta.plan, isNull, reason: 'both fields always written');
      expect(order, ['ensure', 'sid'],
          reason: 'registered on disk before the session id is resolved');
    });

    test('a later plan mutation keeps the goal (paired write)', () async {
      goals.set(cid, 'ship it');
      await binder.flush();
      plans.update(cid, [PlanItem('step')]);
      await binder.flush();
      final meta = store.metaFor(sid, cid)!;
      expect(meta.goal!['text'], 'ship it');
      expect((meta.plan!['items'] as List), hasLength(1));
    });

    test('clearing one tracker keeps the other', () async {
      goals.set(cid, 'ship it');
      plans.update(cid, [PlanItem('step')]);
      await binder.flush();
      goals.clear(cid);
      await binder.flush();
      final meta = store.metaFor(sid, cid)!;
      expect(meta.goal, isNull);
      expect(meta.plan, isNotNull);
    });

    test('verdict recording persists too', () async {
      goals.set(cid, 'ship it');
      await binder.flush();
      goals.recordVerdict(cid, GoalVerdict.achieved, 'tests pass');
      await binder.flush();
      final status = store.metaFor(sid, cid)!.goal!['status'] as Map;
      expect(status['verdict'], 'achieved');
      expect(status['evidence'], 'tests pass');
    });

    test('hydration fills the stores without an echo write', () async {
      binder.hydrate(ConversationMeta(
        id: cid,
        goal: {'text': 'restored'},
        plan: {
          'items': [
            {'text': 'a', 'state': 'pending'}
          ],
          'approval': 'approved',
        },
      ));
      expect(goals.read(cid).text, 'restored');
      expect(plans.read(cid).items.single.text, 'a');
      expect(plans.read(cid).approval, PlanApproval.approved);
      await binder.flush();
      expect(store.metaFor(sid, cid)!.goal, isNull,
          reason: 'reading the manifest must not write it straight back');
      expect(store.metaFor(sid, cid)!.plan, isNull);
      expect(order, isEmpty);
    });

    test('hydrate is authoritative: a null meta clears stale trackers', () {
      goals.set(cid, 'stale');
      plans.update(cid, [PlanItem('stale')]);
      binder.hydrate(null, conversationId: cid);
      expect(goals.read(cid).isEmpty, isTrue);
      expect(plans.read(cid).isEmpty, isTrue);
    });

    test('hydrateAll restores every meta of a manifest', () async {
      final other = await store.createConversation(sid);
      binder.hydrateAll([
        ConversationMeta(id: cid, goal: {'text': 'one'}),
        ConversationMeta(
            id: other,
            plan: {
              'items': [
                {'text': 'two', 'state': 'pending'}
              ],
            }),
      ]);
      expect(goals.read(cid).text, 'one');
      expect(goals.read(other).isEmpty, isTrue);
      expect(plans.read(other).items.single.text, 'two');
      expect(plans.read(cid).isEmpty, isTrue);
    });

    test('a persist failure is swallowed and never breaks the chain',
        () async {
      final doomedGoals = GoalStore();
      addTearDown(doomedGoals.dispose);
      final doomedPlans = PlanStore();
      addTearDown(doomedPlans.dispose);
      final bad = TrackerPersistence(
        goalStore: doomedGoals,
        planStore: doomedPlans,
        store: store,
      )..install(
          sessionIdFor: (_) => 'no-such-session',
          ensureRegisteredFor: (_) async {},
        );
      doomedGoals.set(cid, 'doomed');
      await bad.flush(); // resolves despite the StateError inside
      expect(store.metaFor(sid, cid)!.goal, isNull);
      doomedPlans.update(cid, [PlanItem('x')]);
      await bad.flush(); // the chain still processes later writes
    });

    test('a null session id skips the write entirely', () async {
      final ghostGoals = GoalStore();
      addTearDown(ghostGoals.dispose);
      final ghostPlans = PlanStore();
      addTearDown(ghostPlans.dispose);
      var ensured = false;
      final ghost = TrackerPersistence(
        goalStore: ghostGoals,
        planStore: ghostPlans,
        store: store,
      )..install(
          sessionIdFor: (_) => null,
          ensureRegisteredFor: (_) async {
            ensured = true;
          },
        );
      ghostGoals.set('ghost', 'x');
      await ghost.flush();
      expect(store.metaFor(sid, cid)!.goal, isNull);
      expect(ensured, isTrue,
          reason: 'registration is keyed by conversation, runs before the '
              'session lookup, and is harmless without a write');
    });

    test('persistIfPresent skips empty trackers and writes present ones',
        () async {
      // Empty → skip: no ensure/session lookup, no store traffic.
      binder.persistIfPresent(cid);
      await binder.flush();
      expect(order, isEmpty, reason: 'nothing to persist → no store traffic');
      expect(store.metaFor(sid, cid)!.goal, isNull);

      // Mutate a store BEFORE any binder hooks it (the headless dispatch
      // window), then a fresh binder catches up via persistIfPresent.
      final lateGoals = GoalStore();
      addTearDown(lateGoals.dispose);
      final latePlans = PlanStore();
      addTearDown(latePlans.dispose);
      lateGoals.set(cid, 'headless');
      expect(store.metaFor(sid, cid)!.goal, isNull,
          reason: 'no hook existed at mutation time');
      final lateOrder = <String>[];
      final catchUp = TrackerPersistence(
        goalStore: lateGoals,
        planStore: latePlans,
        store: store,
      )..install(
          sessionIdFor: (id) {
            lateOrder.add('sid');
            return sid;
          },
          ensureRegisteredFor: (id) async {
            lateOrder.add('ensure');
          },
        );
      catchUp.persistIfPresent(cid);
      await catchUp.flush();
      expect(store.metaFor(sid, cid)!.goal!['text'], 'headless');
      expect(lateOrder, ['ensure', 'sid']);
    });

    test('uninstall detaches the hooks', () async {
      binder.uninstall();
      goals.set(cid, 'gone');
      await binder.flush();
      expect(store.metaFor(sid, cid)!.goal, isNull);
      expect(order, isEmpty);
    });
  });
}
