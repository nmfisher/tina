import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/goal_status_renderer.dart';

/// Mounts the goal tracker: the shared [GoalStore] service, the strip
/// [GoalStatusSource] + [GoalStatusRenderer], and the `/goal` command.
///
/// The per-conversation pieces — the request middleware that shows the agent
/// its goal, and the post-turn goal judge — are NOT scope contributions: a
/// shared scope spans every live conversation and cannot tell which
/// conversation a turn belongs to, so `buildAgent` mints the middleware per
/// conversation from the store it finds under [goalStoreServiceKey], and the
/// host layer wires the judge hook when it constructs the turn executor.
PluginDescriptor goalUiPlugin({required GoalStore store}) => PluginDescriptor(
      id: 'tina.goal',
      provides: [goalStoreServiceKey],
      factory: FnPluginFactory((context) {
        // The store instance is the plugin's root object; the runtime binds
        // `provides` keys itself AFTER the factory returns. Do NOT also
        // scope.provide(goalStoreServiceKey) here — the second bind throws
        // "already provided in scope execution" at activation (the same trap
        // the plan plugin's comment documents).
        context.register(
          GoalStatusSource(store),
          id: 'tina.goal.status',
        );
        context.register(
          const GoalStatusRenderer(),
          id: 'tina.goal.renderer',
        );
        context.register(
          goalCommand(store),
          id: 'tina.goal.command',
        );
        return store;
      }),
    );
