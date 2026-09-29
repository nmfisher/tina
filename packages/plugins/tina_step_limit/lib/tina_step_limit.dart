import 'package:tina_engine_2/tina_engine_2.dart';
import 'src/config.dart';
export 'src/config.dart';

/// An optional ceiling on foreground rounds, never on individual tools or
/// background provider calls. Each session must receive its own instance.
class StepLimitPlugin extends AgentPlugin {
  StepLimitPlugin({int maxStepsPerTurn = 0, int Function()? readLimit})
      : _readLimit =
            readLimit ?? (() => StepLimitConfig.validate(maxStepsPerTurn));

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
      context.requestStop(id, 'step_limit',
          detail:
              'Model round limit ($_limit) reached. Send another message to continue.');
      return;
    }
    _rounds++;
  }
}
