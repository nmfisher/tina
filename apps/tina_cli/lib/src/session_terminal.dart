/// The application's [Terminal]: session notices and correlated
/// ordinary questions, shared by headless execution and terminal attachments.
/// It owns no screen or terminal modes. Frontends read through a connection.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_host/tina_host.dart' show SessionQuestions, SessionNotices;

/// The session [Terminal]: writes append to the conversation;
/// asks use the session-owned question service.
final class SessionTerminal implements Terminal {
  SessionTerminal({SessionQuestions? questions, SessionNotices? notices})
    : questions = questions ?? SessionQuestions(),
      notices = notices ?? SessionNotices();

  final SessionQuestions questions;
  final SessionNotices notices;

  @override
  void writeln([String? line]) {
    final text = line ?? '';
    notices.write(text);
  }

  @override
  Future<String> ask(String prompt) async {
    final result = await questions.ask(prompt);
    // Legacy Terminal callers treat an empty answer as cancellation. New
    // callers can inspect the explicit disposition on QuestionResult.
    return result.text;
  }

  /// Owner shutdown; view detach must never call this method.
  void closeInput() => questions.close();
}
