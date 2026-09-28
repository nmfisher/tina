/// One session: its id, its conversation, and its details.
///
/// The conversation truth is the loop's — it is the only writer of the
/// transcript — so the session holds the loop and records the turns. One
/// host owns one session; there is no registry. The session carries no
/// permission mode: that value lives with the plugin that owns the
/// enforcement boundary, never here.
///
/// The **details** are the small counters a host (or a plugin) wants to
/// survive a resume: this session's [depth], how many [children] it has
/// in flight right now, and the [tokensSpent] booking the work its
/// children did. They live in one mutable [SessionDetails] value, are
/// persisted with the session's registry row (`tina.session`), and come
/// back with [Host.resume] — a resumed session reads the same numbers
/// the running one had. Details are facts about the session, not
/// decisions; deciding what a depth or a budget means is the caller's
/// business.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

/// One session, owned by one [Host].
final class Session {
  Session({
    required this.id,
    required this.loop,
    SessionDetails? details,
  }) : details = details ?? SessionDetails();

  /// Unique within the process. Two hosts never share a session.
  final String id;

  /// The conversation: transcript, requests, responses. Nothing else in
  /// the host appends to it.
  final AgentLoop loop;

  /// This session's counters — depth, children in flight, tokens spent.
  /// Mutable by design; the store persists whatever they hold when a
  /// save happens, and a resume restores them.
  final SessionDetails details;

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
    return [for (final b in last.content.whereType<TextBlock>()) b.text].join();
  }
}
