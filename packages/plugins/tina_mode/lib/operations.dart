import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_host/tina_host.dart';
import 'tina_mode.dart';

final modeOperations = <String, SessionOperation>{
  'set': SessionOperation.control((plugin, arguments) {
    final selected = _mode(arguments['mode']);
    final expected = _mode(arguments['expected_mode']);
    if (arguments.length != 2 || selected == null || expected == null) {
      return const SessionResult(
        stopReason: StopReason.error,
        detail: 'Invalid permission mode change.',
      );
    }
    final policy = (plugin as ModePolicySource).modePolicy;
    if (policy.mode != expected) {
      return const SessionResult(
        stopReason: StopReason.error,
        detail: 'Permission mode changed in another client. Try again.',
      );
    }
    policy.selectMode(selected, expectedMode: expected);
    return const SessionResult();
  }, allowWhileRunning: true),
};

PermissionMode? _mode(Object? name) {
  for (final mode in PermissionMode.values) {
    if (mode.name == name) return mode;
  }
  return null;
}
