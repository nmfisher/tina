import 'package:test/test.dart';
import 'package:tina/composition/plan_ui.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

/// Regression for the v0.8.22 release failure: the plugin factory called
/// `scope.provide(planStoreServiceKey, …)` while ALSO declaring
/// `provides: [planStoreServiceKey]`, and the runtime's own post-factory
/// bind of declared keys then threw "already provided in scope execution" —
/// which only surfaced in the startup smoke test, because no unit test
/// activated the plugin through a real [PluginRuntime]. These tests do.
void main() {
  test('planUiPlugin activates in a PluginRuntime and provides the store', () {
    final store = PlanStore();
    final runtime = PluginRuntime(
      name: 'plan-ui-test',
      plugins: [planUiPlugin(store: store)],
    )..activateSync();
    addTearDown(runtime.dispose);

    expect(runtime.stateOf('tina.plan'), PluginLifecycleState.active);
    expect(runtime.scope.lookup(planStoreServiceKey), same(store));
  });

  test('the store works end-to-end through the activated scope', () {
    final store = PlanStore();
    final runtime = PluginRuntime(
      name: 'plan-ui-e2e-test',
      plugins: [planUiPlugin(store: store)],
    )..activateSync();
    addTearDown(runtime.dispose);

    final fromScope = runtime.scope.lookup(planStoreServiceKey)!;
    fromScope.update('c1', [(text: 'a', state: PlanState.pending)]);
    expect(store.read('c1').items.single.text, 'a');
    expect(identical(fromScope, store), isTrue);
  });
}
