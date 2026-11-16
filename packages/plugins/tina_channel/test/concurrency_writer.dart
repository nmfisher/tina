// A channel-store writer used by the two-process concurrency test and
// the live multi-process verification. Run as a real dart process:
//
//   dart run test/concurrency_writer.dart DB MY_NAME OTHER_NAME COUNT
//
// It opens the shared database (its own connection), joins #stress,
// posts COUNT messages, then polls until it has read the other
// writer's messages too, and prints one machine-readable summary line:
//
//   SUMMARY name=NAME posted=COUNT statusAnnounced=1 sawOther=SEEN
//
// Exit code 0 means the writer saw the other side; 65 means timeout.
import 'dart:io';

import 'package:tina_channel/tina_channel_sqlite.dart';

void main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: concurrency_writer.dart DB MY OTHER COUNT');
    exit(64);
  }
  final db = args[0];
  final mine = args[1];
  final other = args[2];
  final count = int.parse(args[3]);
  final store = SqliteChannelStore.open(db);
  store.setMember(
      '#stress', mine, status: 'working', role: 'agent', announce: true);
  for (var i = 1; i <= count; i++) {
    store.post('#stress', sender: mine, text: '$mine message $i');
  }

  // Cross-process visibility: poll until the other writer's rows
  // appear through this connection.
  var sawOther = 0;
  for (var attempt = 0; attempt < 200; attempt++) {
    sawOther = store
        .read('#stress', limit: 200)
        .where((m) => m.sender == other)
        .length;
    if (sawOther > 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  store.close();
  if (sawOther == 0) {
    stderr.writeln('$mine never saw $other');
    exit(65);
  }
  stdout.writeln('SUMMARY name=$mine posted=$count sawOther=$sawOther');
  exit(0);
}
