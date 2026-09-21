import 'package:tina_engine/tina_engine.dart' show SessionMeta;

/// Select before building project context or entering the TUI. Synchronous
/// line input leaves stdin available for the terminal's later input backend.
String? pickStartupSession(
  List<SessionMeta> sessions, {
  required String? Function() readLine,
  required void Function(String) write,
}) {
  if (sessions.isEmpty) {
    write('No saved sessions.\n');
    return null;
  }
  final sorted = List<SessionMeta>.of(sessions)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  String line(String value) =>
      value.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
  write('Saved sessions (most recent first):\n');
  for (var i = 0; i < sorted.length; i++) {
    final session = sorted[i];
    final stamp = session.updatedAt.toLocal().toString().substring(0, 16);
    write(
      '${i + 1}. ${line(session.title)}  $stamp  '
      '${session.messageCount} messages\n'
      '   ${line(session.id)}'
      '${session.cwd == null ? '' : '  ${line(session.cwd!)}'}\n',
    );
  }
  while (true) {
    write('Session number (Enter or q to cancel): ');
    final answer = readLine()?.trim();
    if (answer == null || answer.isEmpty || answer.toLowerCase() == 'q')
      return null;
    final number = int.tryParse(answer);
    if (number != null && number >= 1 && number <= sorted.length)
      return sorted[number - 1].id;
    write('Choose a number from 1 to ${sorted.length}.\n');
  }
}
