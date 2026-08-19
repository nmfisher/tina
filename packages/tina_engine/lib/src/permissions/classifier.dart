import 'dart:async';
import 'dart:convert';

import '../llm/message.dart';
import '../llm/provider.dart';

/// One-shot safety judge for permission mode "auto": decides whether a tool
/// call may run without asking the user. Any failure — network error, stream
/// error, timeout, unparseable answer — yields null, and the caller falls
/// back to the interactive prompt (fail-open only toward asking a human).
class PermissionClassifier {
  final LlmProvider provider;
  final Duration timeout;

  PermissionClassifier(this.provider, {this.timeout = const Duration(seconds: 15)});

  static const _systemPrompt = 'You are the safety gate for a coding agent '
      'running in a project directory. You are shown one tool call. Answer '
      'with exactly one word: ALLOW or DENY.\n'
      'DENY anything destructive or irreversible (deleting data, force-pushing, '
      'reformatting disks), anything that exfiltrates secrets or source code to '
      'third parties, and anything touching files well outside the working '
      'tree.\n'
      'ALLOW ordinary development: reading, searching, editing project files, '
      'building, testing, and routine shell commands.\n'
      'When uncertain, DENY — a human will review the call.';

  /// Returns true (allow) / false (deny) / null (undecidable — ask the user).
  Future<bool?> allow(String toolName, Map<String, dynamic> input) async {
    try {
      final stream = provider.send(
        system: _systemPrompt,
        messages: [
          Message(role: Role.user, content: [
            TextBlock('Tool: $toolName\nInput:\n${jsonEncode(input)}'),
          ]),
        ],
        tools: const [],
      );

      final buf = StringBuffer();
      final done = Completer<void>();
      Object? err;

      final sub = stream.listen(
        (event) {
          if (event is TextDelta) {
            buf.write(event.text);
          } else if (event is StreamError) {
            err = event.error;
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          err = e;
          if (!done.isCompleted) done.complete();
        },
      );

      try {
        await done.future.timeout(timeout);
      } on TimeoutException {
        await sub.cancel();
        return null;
      }

      if (err != null) return null;
      final answer = buf.toString().toUpperCase();
      if (answer.contains('ALLOW')) return true;
      if (answer.contains('DENY')) return false;
      return null;
    } catch (_) {
      return null;
    }
  }
}
