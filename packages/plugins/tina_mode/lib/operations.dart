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
    // Pattern-narrowed, never cast (commit 28): an unrelated interface
    // does not promote through `is`, and absence is an error result —
    // not a type-cast failure.
    if (plugin case ModePolicySource source) {
      final policy = source.modePolicy;
      if (policy.mode != expected) {
        return const SessionResult(
          stopReason: StopReason.error,
          detail: 'Permission mode changed in another client. Try again.',
        );
      }
      policy.selectMode(selected, expectedMode: expected);
      return const SessionResult();
    }
    return const SessionResult(
      stopReason: StopReason.error,
      detail: 'The mode policy is not available in this session.',
    );
  }, allowWhileRunning: true),
};

PermissionMode? _mode(Object? name) {
  for (final mode in PermissionMode.values) {
    if (mode.name == name || mode.label == name) return mode.normalized;
  }
  return null;
}
