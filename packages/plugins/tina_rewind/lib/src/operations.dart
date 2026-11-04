import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_host/tina_host.dart';

import 'plugin.dart';

/// Operations the rewind plugin serves over the host's operations channel,
/// so a connected console can rewind through the same path `/rewind` uses.
final rewindOperations = <String, SessionOperation>{
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
      (plugin as RewindPlugin).rewindTo(
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
