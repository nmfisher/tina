// Validates ReplySequenceFilter against a *captured* pump event log — the
// strongest evidence available without wiring the filter into the backend.
//
// Capture a log with tool/reply_decode_spike.dart (repo root) while injecting
// tool/tmux_inject_replies.sh and pasting/typing controls, then:
//   dart run tool/validate_reply_filter.dart /tmp/reply_spike.log
//
// Prints how much of the stream the filter passed. Expected on a capture with
// one reply bundle, one genuine paste and some typing: the two ~4800-event
// reply bursts are swallowed, the paste and the typed keys pass verbatim.
import 'dart:io';

import 'package:tina_console/src/backend/reply_sequence_filter.dart';

void main(List<String> args) {
  final log = args.isNotEmpty ? args[0] : '/tmp/reply_spike.log';
  final filter = ReplySequenceFilter();
  final out = <int>[];
  var n = 0;
  for (final line in File(log).readAsLinesSync()) {
    if (!line.startsWith(RegExp(r'^\d'))) continue;
    final parts = line.split('\t');
    final ms = int.parse(parts[0]);
    final id = int.parse(parts[1].split('=')[1]);
    out.addAll(filter.add(id, ms * 1000)); // ms resolution → µs
    n++;
  }
  out.addAll(filter.flush());
  final text = String.fromCharCodes(
    out.where((c) => c >= 0x20 && c < 0x7f),
  );
  print('input events : $n');
  print('passed events: ${out.length}');
  print('any ESC passed: ${out.contains(0x1b)}');
  print('passed text  : "${text.length > 200 ? '${text.substring(0, 200)}...' : text}"');
}
