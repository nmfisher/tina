/// The [Terminal] the TUI contributes to a session: a text sink into the
/// conversation view, and a queued answer for questions.
///
/// A text sink, not the renderer — plugin lines land as conversation rows
/// the host paints; commands are never routed through drawing code. The
/// ask seam is the input path inverted: a [TuiTerminal.ask] parks a
/// completer and resolves with whatever the host feeds
/// [TuiTerminal.submitAnswer] — a raw-mode host from its parser, a test
/// from a list. No terminal anywhere in here.
library;

import 'dart:async';

import 'package:tina_services/tina_services.dart';

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

/// The [Terminal] over the TUI: writes append to the conversation;
/// asks resolve from a queue of answers.
final class TuiTerminal implements Terminal {
  final List<ConversationLine> _lines = [];

  /// Every line written through [writeln] and every submitted answer,
  /// oldest first — the host reads this to repaint the conversation view.
  List<ConversationLine> get lines => List.unmodifiable(_lines);

  /// Answers waiting to be handed to asks, oldest first. A test seeds it;
  /// a raw-mode host appends as the user types. An ask with an empty
  /// queue waits — nothing is invented.
  final List<String> answers = [];

  @override
  void writeln([String? line]) {
    _lines.add(ConversationLine(line ?? '', fromUser: false));
  }

  @override
  Future<String> ask(String prompt) {
    _lines.add(ConversationLine(prompt, fromUser: false));
    if (answers.isNotEmpty) {
      return Future.value(answers.removeAt(0));
    }
    final wait = Completer<String>();
    _pending.add(wait);
    return wait.future;
  }

  final List<Completer<String>> _pending = [];

  /// Answer the oldest pending ask (or queue the answer for the next one,
  /// when nothing is waiting). Resolves the future [ask] returned.
  void submitAnswer(String answer) {
    if (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(answer);
    } else {
      answers.add(answer);
    }
  }

  /// End-of-input: every ask still waiting resolves `''` — the same
  /// answer an empty line gives, never a hang, never an exception.
  void closeInput() {
    for (final wait in _pending) {
      wait.complete('');
    }
    _pending.clear();
  }
}
