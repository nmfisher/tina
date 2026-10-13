import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_session_controls/tina_session_controls.dart';

Host controlsHost({ModePlugin? mode, SessionControlsPlugin? controls}) {
  final host = Host.start(HostConfig(
    workingDirectory: '.',
    providerFactory: (_) => ScriptedProvider([]),
    plugins: [if (mode != null) mode, if (controls != null) controls],
    operationsFor: (plugin) =>
        plugin is ModePlugin ? modeOperations : sessionControlsOperations,
    snapshotFeatureFor: (plugin) {
      if (plugin is ModePlugin) {
        return SnapshotFeature(() => {'mode': plugin.mode.name},
            listen: (changed) => plugin.listen((_) => changed()));
      }
      final data = (plugin as SessionControlsPlugin).observation;
      return SnapshotFeature(() => {
            'model': data.currentModel,
            'models': data.catalog.models,
            'provider_names': data.catalog.providerNames,
            'model_names': data.catalog.modelNames,
            'recent_models': data.recentModels,
          });
    },
  ));
  addTearDown(host.shutdown);
  return host;
}
