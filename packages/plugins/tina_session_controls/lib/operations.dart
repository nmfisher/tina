import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_host/tina_host.dart';
import 'tina_session_controls.dart';

final sessionControlsOperations = <String, SessionOperation>{
  'select-model': SessionOperation.control((plugin, arguments) {
    final model = arguments['model'];
    final expected = arguments['expected_model'];
    if (arguments.length != 2 ||
        model is! String ||
        expected is! String ||
        model.isEmpty ||
        expected.isEmpty) {
      return const SessionResult(
        stopReason: StopReason.error,
        detail: 'Invalid model selection.',
      );
    }
    final controls = plugin as SessionControlsPlugin;
    if (controls.currentModel() != expected) {
      return const SessionResult(
        stopReason: StopReason.error,
        detail: 'Model changed in another client. Open the picker again.',
      );
    }
    if (!controls.modelCatalog().models.contains(model)) {
      return const SessionResult(
        stopReason: StopReason.error,
        detail: 'Selected model is no longer available. Open the picker again.',
      );
    }
    // Model switching runs during compaction but never during a live turn.
    // A live turn owns its request stream. Switching only re-points future
    // requests. The host rejects a mid-turn request at admission. If the
    // switch still throws, the host sanitizes the error, so provider
    // details never reach the client.
    controls.selectModel(model, expectedModel: expected);
    return const SessionResult();
  }, allowWhileRunning: true, requiresIdleTurn: true),
};
