import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';

/// Real native pump probe; the PTY driver supplies mouse reports, not key mocks.
Future<void> main(List<String> arguments) async {
  final path = arguments.single;
  final backend = NotcursesBackend.create(io: const LiveStdio());
  backend.enterAltScreen();
  final input = backend.createInputBackend();
  final events = <Map<String, Object>>[];
  final done = Completer<void>();
  final subscription = input.events.listen((event) {
    if (event is! MouseEvent) return;
    events
        .add({'action': event.action.name, 'row': event.row, 'col': event.col});
    File(path).writeAsStringSync(jsonEncode(events));
    if (event.action == MouseAction.release && !done.isCompleted)
      done.complete();
  });
  try {
    await input.ready;
    backend.setMouseReporting(true);
    File('$path.ready').writeAsStringSync('ready');
    await done.future.timeout(const Duration(seconds: 5));
    File(path).writeAsStringSync(jsonEncode(events));
  } finally {
    await subscription.cancel();
    input.dispose();
    backend.leaveAltScreen();
  }
}
