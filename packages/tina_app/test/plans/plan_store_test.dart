import 'dart:convert';

import 'package:tina_app/tina_app.dart';
import 'package:test/test.dart';

void main() {
  late PlanStore store;
  setUp(() {
    store = PlanStore();
  });
  tearDown(() {
    store.dispose();
  });

  test('read on unknown conversation yields the empty plan', () {
    final plan = store.read('c1');
    expect(plan.isEmpty, isTrue);
    expect(plan.summary, '');
  });

  test('update replaces wholesale and fires changes', () async {
    final seen = <int>[];
    final sub = store.changes.listen((_) => seen.add(seen.length + 1));
    store.update('c1', [
      (text: 'set up tests', state: PlanState.done),
      (text: 'regex fix', state: PlanState.inProgress),
      (text: 'ship it', state: PlanState.pending),
    ]);
    final plan = store.read('c1');
    expect(plan.items.map((i) => i.text),
        ['set up tests', 'regex fix', 'ship it']);
    expect(plan.summary, 'regex fix · 1/3');
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 1);
    await sub.cancel();
  });

  test('at most one in-progress item', () {
    expect(
      () => store.update('c1', [
        (text: 'a', state: PlanState.inProgress),
        (text: 'b', state: PlanState.inProgress),
      ]),
      throwsArgumentError,
    );
    // Whitespace-only text is empty after trim.
    expect(
      () => store.update('c1', [(text: '   ', state: PlanState.pending)]),
      throwsArgumentError,
    );
    expect(store.read('c1').isEmpty, isTrue);
  });

  test('clear removes the plan and fires once only when present', () async {
    final seen = <int>[];
    final sub = store.changes.listen((_) => seen.add(seen.length + 1));
    store.update('c1', [(text: 'a', state: PlanState.pending)]);
    store.clear('c1');
    store.clear('c1');
    expect(store.read('c1').isEmpty, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 2);
    await sub.cancel();
  });

  test('conversations are isolated', () {
    store.update('c1', [(text: 'a', state: PlanState.pending)]);
    expect(store.read('c2').isEmpty, isTrue);
    store.clear('c2');
    expect(store.read('c1').items.single.text, 'a');
  });

  test('update rejects over-limit plans', () {
    expect(
      () => store.update(
        'c1',
        List.generate(
          PlanStore.maxItems + 1,
          (i) => (text: 'item $i', state: PlanState.pending),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => store.update('c1', [
        (text: 'x' * (PlanStore.maxTextLength + 1), state: PlanState.pending),
      ]),
      throwsArgumentError,
    );
  });

  test('after dispose, mutations throw', () {
    store.dispose();
    expect(
      () => store.update('c1', [(text: 'a', state: PlanState.pending)]),
      throwsStateError,
    );
  });

  group('Plan persistence (JSON + hydrate)', () {
    test('Plan JSON round-trips items, states and approval', () {
      final plan = Plan([
        (text: 'set up tests', state: PlanState.done),
        (text: 'regex fix', state: PlanState.inProgress),
      ], approval: PlanApproval.requested);
      // Through an actual JSON encode/decode, like a manifest round-trip.
      final back = Plan.fromJson(
          jsonDecode(jsonEncode(plan.toJson())) as Map<String, dynamic>);
      expect(back.items, plan.items);
      expect(back.approval, PlanApproval.requested);
    });

    test('a fresh plan serializes approval none', () {
      expect(const Plan([]).toJson(), {
        'items': const [],
        'approval': 'none',
      });
    });

    test('fromJson is lenient: junk skipped, caps and invariants re-applied',
        () {
      final plan = Plan.fromJson(jsonDecode(jsonEncode({
        'items': [
          {'text': 'first', 'state': 'inProgress'},
          {'text': 'second', 'state': 'inProgress'}, // second → demoted
          {'text': '   ', 'state': 'pending'}, // blank → skipped
          17, // junk → skipped
          {'state': 'pending'}, // missing text → skipped
          {'text': 'odd', 'state': 'finished'}, // unknown state → pending
          {'text': 'x' * 300, 'state': 'done'}, // text capped
        ],
        'approval': 'rubber-stamped', // unknown → none
      })) as Map<String, dynamic>);
      expect(plan.items.map((i) => i.text),
          ['first', 'second', 'odd', 'x' * PlanStore.maxTextLength]);
      expect(plan.items.map((i) => i.state), [
        PlanState.inProgress,
        PlanState.pending,
        PlanState.pending,
        PlanState.done,
      ]);
      expect(plan.approval, PlanApproval.none);
    });

    test('an overlong item list truncates at the cap', () {
      final plan = Plan.fromJson({
        'items': [
          for (var i = 0; i < PlanStore.maxItems + 10; i++)
            {'text': 'i$i', 'state': 'pending'},
        ],
      });
      expect(plan.items, hasLength(PlanStore.maxItems));
    });

    test('persistHook fires on update/approval/clear, never on hydrate', () {
      final hooks = PlanStore();
      final hooked = <String>[];
      hooks.persistHook = hooked.add;
      expect(
        () => hooks.update('c1', [(text: ' ', state: PlanState.pending)]),
        throwsArgumentError,
      );
      hooks.update('c1', [(text: 'a', state: PlanState.pending)]);
      hooks.approve('c1');
      hooks.approve('c1'); // unchanged approval → no mutation, no hook
      hooks.clear('c1');
      hooks.clear('c1'); // nothing existed → no hook
      expect(hooked, ['c1', 'c1', 'c1']);
      hooks.hydrate('c1', {
        'items': [
          {'text': 'restored', 'state': 'pending'}
        ],
      });
      expect(hooked, ['c1', 'c1', 'c1'],
          reason: 'hydration IS the restore; writing back would be an echo');
      expect(hooks.read('c1').items.single.text, 'restored');
      hooks.dispose();
    });

    test('hydrate restores, is authoritative, and never throws', () async {
      final plans = PlanStore();
      var changes = 0;
      final sub = plans.changes.listen((_) => changes++);
      const blob = {
        'items': [
          {'text': 'step', 'state': 'done'},
        ],
        'approval': 'approved',
      };

      plans.hydrate('c1', blob);
      await Future<void>.delayed(Duration.zero);
      expect(plans.read('c1').items.single.state, PlanState.done);
      expect(plans.read('c1').approval, PlanApproval.approved);
      expect(changes, 1);

      plans.hydrate('c1', blob); // identical → no spurious repaint
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);

      plans.hydrate('c1', null); // manifest authoritative → clear
      await Future<void>.delayed(Duration.zero);
      expect(plans.read('c1').isEmpty, isTrue);
      expect(changes, 2);

      plans.hydrate('c1', {'items': 'garbage'}); // corrupt → degrades to clear
      expect(plans.read('c1').isEmpty, isTrue);

      plans.dispose();
      expect(() => plans.hydrate('c1', blob), returnsNormally,
          reason: 'a disposed store must not break a resume');
      await sub.cancel();
    });
  });
}
