import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';
import 'src/config.dart';
export 'src/config.dart';

/// An optional ceiling on foreground rounds, never on individual tools or
/// background provider calls. Each session must receive its own instance.
class StepLimitPlugin extends AgentPlugin {
  StepLimitPlugin({int maxStepsPerTurn = 0, int Function()? readLimit})
      : _readLimit =
            readLimit ?? (() => StepLimitConfig.validate(maxStepsPerTurn));

  /// Read the effective policy at the start of each turn. Standalone callers
  /// without scoped settings retain the existing global config-file format.
  factory StepLimitPlugin.configured(
      {required String configPath, ScopedSettings? settings}) {
    final config = StepLimitConfig(configPath);
    return StepLimitPlugin(
        readLimit: () =>
            settings?.read(stepLimitSetting).value ?? config.read());
  }

  final int Function() _readLimit;
  int _limit = 0;
  int _rounds = 0;

  @override
  String get id => 'tina/step-limit';

  // Run before request preparation that can make auxiliary provider calls.
  @override
  int get order => -1000;

  @override
  void onInput(TurnContext context) {
    _limit = StepLimitConfig.validate(_readLimit());
    _rounds = 0;
  }

  @override
  void beforeModelCall(TurnContext context) {
    if (_limit > 0 && _rounds >= _limit) {
      context.requestStop('step_limit',
          detail:
              'Model round limit ($_limit) reached. Send another message to continue.');
      return;
    }
    _rounds++;
  }
}
