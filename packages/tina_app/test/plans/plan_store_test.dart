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
}
