import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/plan_status_renderer.dart';

/// Mounts the plan tracker: the shared [PlanStore] service, the strip
/// [PlanStatusSource] + [PlanStatusRenderer], and the `/plan` command.
///
/// The per-conversation pieces — the `update_plan` tool and the request
/// middleware that shows the agent its plan — are NOT scope contributions:
/// a shared scope spans every live conversation and cannot tell which
/// conversation a turn belongs to, so `buildAgent` mints them per
/// conversation from the store it finds under [planStoreServiceKey].
PluginDescriptor planUiPlugin({required PlanStore store}) => PluginDescriptor(
      id: 'tina.plan',
      provides: [planStoreServiceKey],
      factory: FnPluginFactory((context) {
        context.scope.provide(planStoreServiceKey, store);
        context.register(
          PlanStatusSource(store),
          id: 'tina.plan.status',
        );
        context.register(
          const PlanStatusRenderer(),
          id: 'tina.plan.renderer',
        );
        context.register(
          planCommand(store),
          id: 'tina.plan.command',
        );
        return store;
      }),
    );
