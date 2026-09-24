import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import 'typesafe.dart';

/// PT0 (docs/proposals/plugin-first-tools/01): `explore_project` crosses the
/// scope like every other registry tool instead of being constructed in the
/// launcher and hand-threaded (bin/tina.dart → TuiCoordinator → buildAgent →
/// callers). The tool is self-configuring — its `open` resolves credentials
/// and settings at invocation — so the plugin mounts unconditionally and the
/// tool fails closed (null lease → nothing to explore) when Typesafe isn't
/// configured, the same shape as `web_search`.
///
/// The spend ledger is a `require`: declaring the dependency pins this plugin
/// after `tina.app.spend-ledger` in the activation order, so the metered
/// service never meters against a missing ledger. The pause gate rides the
/// composition the way `workspaceCapabilitiesPlugin` receives it: it is born
/// in the launcher, then shared by `buildAppComposition` (via the new
/// `pauseGate` parameter) and this plugin, so the tool pauses on the same
/// gate as every other spend-aware surface.
PluginDescriptor configuredExploreProjectPlugin({
  required Map<String, String> env,
  required PauseGate pauseGate,
}) {
  return PluginDescriptor(
    id: 'tina.tool.explore-project',
    requires: {spendLedgerServiceKey},
    provides: [exploreProjectToolServiceKey],
    factory: FnPluginFactory((context) {
      final ledger = context.require(spendLedgerServiceKey);
      // The tool IS the factory's product: it is bound to
      // [exploreProjectToolServiceKey] (the runtime binds the factory's
      // return value to every `provides` key), and buildAgent reads it back
      // with a typed lookup. Registering it as a contribution instead would
      // leave the service key holding a marker object — a cast time bomb on
      // every agent build.
      return ExploreProjectTool(
        open: () => openConfiguredExplorationLease(
          env: env,
          spendLedger: ledger,
          pauseGate: pauseGate,
        ),
      );
    }),
  );
}
