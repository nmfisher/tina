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
    controls.selectModel(model, expectedModel: expected);
    return const SessionResult();
  }),
  'rewind': SessionOperation.control((plugin, arguments) {
    final toSeq = arguments['to_seq'];
    final expectedHead = arguments['expected_head'];
    if (arguments.length != 2 || toSeq is! int || expectedHead is! int) {
      return const SessionResult(
        stopReason: StopReason.error,
        detail: 'Invalid rewind request.',
      );
    }
    try {
      (plugin as SessionControlsPlugin).rewindTo(
        toSeq: toSeq,
        expectedHead: expectedHead,
      );
    } on StateError catch (error) {
      return SessionResult(
        stopReason: StopReason.error,
        detail: error.message.isNotEmpty ? error.message : 'Rewind failed.',
      );
    }
    return const SessionResult();
  }),
};
