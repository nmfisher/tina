/// The application's buffered [Terminal]: plugin notices and correlated
/// ordinary questions, shared by headless execution and terminal attachments.
/// It owns no screen or terminal modes. Listeners detach independently.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_host/tina_host.dart' show SessionQuestions;

/// One conversation row: the text and whether it came from the user.
final class ConversationLine {
  final String text;
  final bool fromUser;
  const ConversationLine(this.text, {this.fromUser = false});

  @override
  bool operator ==(Object other) =>
      other is ConversationLine &&
      text == other.text &&
      fromUser == other.fromUser;

  @override
  int get hashCode => Object.hash(text, fromUser);
}

/// The session [Terminal]: writes append to the conversation;
/// asks use the session-owned question service.
final class SessionTerminal implements Terminal {
  SessionTerminal({this.onLine, SessionQuestions? questions})
      : questions = questions ?? SessionQuestions();

  final SessionQuestions questions;

  /// When set, every line written through [writeln] is also handed here
  /// — the full-screen loop paints it into the chat region. A test's
  /// terminal has no hook: the capture in [lines] is the whole story.
  void Function(String line)? onLine;
  final _listeners = <Object, void Function(String)>{};
  void Function() listenLines(void Function(String) listener) {
    final owner = Object();
    _listeners[owner] = listener;
    return () => _listeners.remove(owner);
  }

  final List<ConversationLine> _lines = [];

  /// Written notices and question prompts, oldest first. Answer text stays
  /// with the caller of [ask], rather than being copied into this buffer.
  List<ConversationLine> get lines => List.unmodifiable(_lines);

  @override
  void writeln([String? line]) {
    final text = line ?? '';
    _lines.add(ConversationLine(text, fromUser: false));
    onLine?.call(text);
    for (final item in _listeners.entries.toList()) {
      if (!_listeners.containsKey(item.key)) continue;
      try {
        item.value(text);
      } catch (_) {
        _listeners.remove(item.key);
      }
    }
  }

  @override
  Future<String> ask(String prompt) async {
    _lines.add(ConversationLine(prompt));
    final result = await questions.ask(prompt);
    // Legacy Terminal callers treat an empty answer as cancellation. New
    // callers can inspect the explicit disposition on QuestionResult.
    return result.text;
  }

  /// Owner shutdown; view detach must never call this method.
  void closeInput() => questions.close();
}
