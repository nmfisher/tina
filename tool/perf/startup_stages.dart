/// Instrument the real CLI; the parent driver owns the process-launch clock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tina_core/tina_core.dart';
import 'package:tina_tui/tina_tui.dart';

Future<void> main(List<String> args) async {
  if (await initializeProcessLauncher(args)) return;
  final clock = Stopwatch()..start();
  final stages = <Map<String, Object?>>[];
  void mark(String name) {
    stages.add({'name': name, 'ms': clock.elapsedMicroseconds / 1000});
    // The driver timestamps receipt on its monotonic clock. No assumptions
    // about synchronization between the parent and child clocks are needed.
    stderr.writeln('TINA_PERF $name');
  }

  mark('main');
  final storeIndex = args.indexOf('--store');
  if (storeIndex < 0) throw ArgumentError('probe requires --store');
  final storePath = args[storeIndex + 1];
  var initialCommits = 0;
  int? preRequestCommits;
  var firstEvent = false;
  var firstText = false;
  var lastTick = clock.elapsedMicroseconds;
  var maxGap = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = clock.elapsedMicroseconds;
    final gap = now - lastTick;
    if (gap > maxGap) maxGap = gap;
    lastTick = now;
  });
  String? sessionId;
  int? seedEntries;
  try {
    exitCode = await runCli(
      args,
      diagnostics: AssemblyDiagnostics(
        stage: (stage) {
          mark(stage);
          if (stage == 'assembly-ready') initialCommits = walCommits(storePath);
          if (stage == 'provider-send' && preRequestCommits == null) {
            preRequestCommits = walCommits(storePath) - initialCommits;
          }
        },
        ready: (assembly) {
          sessionId = assembly.host.session.id;
          seedEntries = assembly.host.session.loop.log.length;
        },
        modelEvent: (event) {
          if (!firstEvent) {
            firstEvent = true;
            mark('first-event');
          }
          if (!firstText && event is TextDelta && event.text.isNotEmpty) {
            firstText = true;
            mark('first-text');
          }
        },
      ),
    );
    mark('cli-complete');
    // Let the heartbeat observe the final synchronous work as well.
    await Future<void>.delayed(const Duration(milliseconds: 2));
  } finally {
    timer.cancel();
  }
  stdout.writeln(
    jsonEncode({
      'session_id': sessionId,
      'seed_entries': seedEntries,
      'pre_request_commits': preRequestCommits,
      'max_event_loop_gap_ms': maxGap / 1000,
      'stages': stages,
      'exit_code': exitCode,
    }),
  );
}

/// Count transaction-ending frames in this small, uncheckpointed benchmark
/// WAL. Production never reads WAL files directly. A fresh connection's WAL
/// is counted again at ready, excluding schema/mount work from the send count.
int walCommits(String path) {
  final file = File('$path-wal');
  if (!file.existsSync()) return 0;
  final bytes = file.readAsBytesSync();
  if (bytes.length < 32) return 0;
  final data = ByteData.sublistView(bytes);
  final pageSize = data.getUint32(8);
  var count = 0;
  for (
    var offset = 32;
    offset + 24 + pageSize <= bytes.length;
    offset += 24 + pageSize
  ) {
    if (data.getUint32(offset + 8) != data.getUint32(16) ||
        data.getUint32(offset + 12) != data.getUint32(20))
      break;
    if (data.getUint32(offset + 4) != 0) count++;
  }
  return count;
}
