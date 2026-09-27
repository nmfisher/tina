/// One session: its id and its conversation.
///
/// The conversation truth is the loop's — it is the only writer of the
/// transcript — so the session holds the loop and records the turns. One
/// host owns one session; there is no registry. The session carries no
/// permission mode: that value lives with the plugin that owns the
/// enforcement boundary, never here.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

/// One session, owned by one [Host].
final class Session {
  Session({
    required this.id,
    required this.loop,
  });

  /// Unique within the process. Two hosts never share a session.
  final String id;

  /// The conversation: transcript, requests, responses. Nothing else in
  /// the host appends to it.
  final AgentLoop loop;

  /// Every finished turn, oldest first. In memory only; persistence is a
  /// later slice.
  final List<Outcome> turns = [];

  /// The assistant's reply to the most recent turn, or null before the
  /// first one finishes.
  String? get lastReply {
    if (turns.isEmpty) return null;
    final replies = turns.last.modelResponses;
    if (replies.isEmpty) return null;
    final last = replies.last;
    return [
      for (final b in last.content.whereType<TextBlock>()) b.text
    ].join();
  }
}
