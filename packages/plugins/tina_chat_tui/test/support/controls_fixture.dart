import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_rewind/tina_rewind.dart';
import 'package:tina_session_controls/tina_session_controls.dart';

Host controlsHost(
    {ModePlugin? mode, SessionControlsPlugin? controls, RewindPlugin? rewind}) {
  final host = Host.start(HostConfig(
    workingDirectory: '.',
    providerFactory: (_) => ScriptedProvider([]),
    plugins: [
      if (mode != null) mode,
      if (controls != null) controls,
      if (rewind != null) rewind,
    ],
    operationsFor: (plugin) => switch (plugin) {
      ModePlugin() => modeOperations,
      RewindPlugin() => rewindOperations,
      SessionControlsPlugin() => sessionControlsOperations,
      _ => const {},
    },
    snapshotFeatureFor: (plugin) {
      switch (plugin) {
        case ModePlugin():
          return SnapshotFeature(() => {'mode': plugin.mode.name},
              listen: (changed) => plugin.listen((_) => changed()));
        case RewindPlugin():
          return SnapshotFeature(() => {
                'rewind_points': [
                  for (final point in plugin.observation.rewindPoints)
                    {
                      'to_seq': point.toSeq,
                      'at': point.at,
                      'label': point.label,
                      'kind': point.kind,
                    },
                ],
                'rewind_head': plugin.observation.rewindHead,
              });
        case SessionControlsPlugin():
          final data = plugin.observation;
          return SnapshotFeature(() => {
                'model': data.currentModel,
                'models': data.catalog.models,
                'provider_names': data.catalog.providerNames,
                'model_names': data.catalog.modelNames,
                'recent_models': data.recentModels,
              });
      }
      return null;
    },
  ));
  addTearDown(host.shutdown);
  return host;
}
