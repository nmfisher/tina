/// Entry point for the `track` CLI.
library;

import 'dart:io';

import 'package:core/core.dart';
import 'package:store/store.dart';

import '../lib/src/commands/add.dart';
import '../lib/src/commands/list.dart';
import '../lib/src/commands/report.dart';

/// Minimal argv dispatch — no args package, on purpose; this fixture
/// exists to be read by agents, not to win design awards.
Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: track <add|list|report> [args]');
    return 64;
  }
  final store = JsonFileStore(
    Platform.environment['TRACK_DB'] ??
        '${Platform.environment['HOME']}/.track/events.jsonl',
  );
  return switch (args.first) {
    'add' => addCommand(store, args.skip(1).toList()),
    'list' => listCommand(store, args.skip(1).toList()),
    'report' => reportCommand(store, args.skip(1).toList()),
    _ => () async {
      stderr.writeln('unknown command: ${args.first}');
      return 64;
    }(),
  };
}

// Exported for the command modules' shared helpers.
typedef EventStore = JsonFileStore;
