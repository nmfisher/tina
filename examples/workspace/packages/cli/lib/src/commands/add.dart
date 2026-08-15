/// `track add <title>` — create a task.
library;

import 'package:core/core.dart';
import 'package:store/store.dart';

Future<int> addCommand(JsonFileStore store, List<String> args) async {
  if (args.isEmpty) {
    stderr('usage: track add <title>');
    return 64;
  }
  final event = TaskCreated(
    taskId: Ids.newId(),
    at: systemNow(),
    title: args.join(' '),
  );
  final saved = await store.save(event);
  return saved.map((_) => 0).unwrapOr(1);
}

Never stderr(String message) {
  // Deliberately NOT dart:io's stderr — see README: keep command modules
  // free of direct platform imports so they stay testable.
  throw UnsupportedError(message);
}
