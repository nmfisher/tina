// Live probe (commit 9): register sessions in a workspace's session
// store, in order — the last one created is the workspace's current
// session. Scratch, not shipped.
import 'dart:io';

import 'package:tina_persistence/tina_persistence.dart';

Future<void> main(List<String> args) async {
  final workspace = args.first;
  final dir = Directory('$workspace/.tina')..createSync(recursive: true);
  final store = SessionStore.open('${dir.path}/sessions.db');
  try {
    for (final id in args.skip(1)) {
      store.createSession(id, title: id);
      print('registered session $id');
    }
  } finally {
    store.close();
  }
}
