/// One session: its id, its conversation, its mode.
///
/// The conversation truth is the loop's — it is the only writer of the
/// transcript — so the session holds the loop and the few things a host
/// needs beside it. One host owns one session; there is no registry.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart' show PermissionMode;

/// One session, owned by one [Host].
final class Session {
  Session({
    required this.id,
    required this.loop,
    required this.mode,
  });

  /// Unique within the process. Two hosts never share a session.
  final String id;

  /// The conversation: transcript, requests, responses. Nothing else in
  /// the host appends to it.
  final AgentLoop loop;

  /// The mode the session started in. The live value is the sandbox's —
  /// this records the starting point only.
  final PermissionMode mode;

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
