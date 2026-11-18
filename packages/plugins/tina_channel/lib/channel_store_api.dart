/// The group-channel store contract, with no sqlite anywhere: the
/// interface the channel tools, the CLI and the TUI pane consume, and
/// the portable value types every implementation shares.
///
/// `sqlite_channel_store.dart`'s sqlite-backed [SqliteChannelStore]
/// implements this natively; a wasm composition root injects an
/// in-memory or preopened-file implementation instead. This library
/// must stay importable where `dart:ffi` cannot go: its import graph is
/// `path` and nothing else.
///
/// The log is append-only by construction: the interface exposes no
/// way to edit or delete a message. Presence and status changes are
/// the one mutable corner — they upsert a `members` row and append a
/// `status` message so the channel shows the shape of the work. The
/// store is designed for several agent processes writing at once
/// (WAL, busy timeout); writers never block readers.
library;

import 'package:path/path.dart' as p;

/// The channel link failed — at open, at write, or mid-read.
final class ChannelStoreException implements Exception {
  const ChannelStoreException(this.message, [this.cause]);

  final String message;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'ChannelStoreException: $message${cause == null ? '' : ' ($cause)'}';
}

/// What kind of row a message is. `message` is agent or user talk,
/// `status` is a presence change (joined / working / idle / done), and
/// `system` is reserved for store-level notices.
enum ChannelMessageType {
  message,
  status,
  system;

  /// The stored string for this type.
  String get name => switch (this) {
        ChannelMessageType.message => 'message',
        ChannelMessageType.status => 'status',
        ChannelMessageType.system => 'system',
      };

  /// Parses the stored string; anything else is a format error.
  static ChannelMessageType parse(String name) => switch (name) {
        'message' => ChannelMessageType.message,
        'status' => ChannelMessageType.status,
        'system' => ChannelMessageType.system,
        _ => throw FormatException('unknown message type: $name'),
      };
}

/// One append-only log row.
final class ChannelMessage {
  const ChannelMessage({
    required this.id,
    required this.channel,
    required this.sender,
    required this.text,
    required this.type,
    required this.createdAt,
    this.mentions = const [],
    this.replyTo,
  });

  /// Rowid picked by the database. Monotonic; the read cursor.
  final int id;

  /// Normalized channel name, leading `#`.
  final String channel;

  /// Self-attributed sender name (agent name + role, or `user`).
  final String sender;

  final String text;

  final ChannelMessageType type;

  /// Parsed `@name` mentions, in first-appearance order.
  final List<String> mentions;

  /// The message id this row replies to, when it is a reply.
  final int? replyTo;

  /// UTC write time.
  final DateTime createdAt;

  @override
  String toString() => '$id $channel $sender'
      '${mentions.isEmpty ? '' : ' @${mentions.join(',@')}'}: $text';
}

/// One member row: an agent's or user's presence in a channel.
final class ChannelMember {
  const ChannelMember({
    required this.channel,
    required this.name,
    required this.role,
    required this.status,
    required this.lastSeen,
    this.summary,
  });

  final String channel;

  /// The sender name messages are self-attributed with.
  final String name;

  /// `agent`, `user`, `subagent`, … — display only.
  final String role;

  /// `working`, `idle`, `done`, `left`, … — display only.
  final String status;

  /// One-line summary of what the member reports.
  final String? summary;

  /// UTC time of the member's last presence write.
  final DateTime lastSeen;

  @override
  String toString() => '$name ($role) $status'
      '${summary == null ? '' : ' — $summary'}';
}

/// One row of the channel listing: what `list` and unread counts need.
final class ChannelSummary {
  const ChannelSummary({
    required this.name,
    required this.messages,
    required this.members,
    required this.lastMessageId,
    this.lastMessageAt,
  });

  final String name;

  /// Total messages of every type.
  final int messages;

  /// Members with a presence row.
  final int members;

  /// Highest message id in the channel, 0 when empty.
  final int lastMessageId;

  final DateTime? lastMessageAt;
}

/// How many recent messages `channel_compact` retains by default.
/// Enough for immediate context after a compaction; everything older
/// is summarized by the digest entry.
const int compactDefaultKeep = 20;

/// Normalizes user or tool input into a stored channel name: trim,
/// lowercase, ensure the leading `#`. Empty input is a format error.
String normalizeChannelName(String input) {
  var name = input.trim().toLowerCase();
  if (name.isEmpty) {
    throw const FormatException('channel name is empty');
  }
  if (!name.startsWith('#')) name = '#$name';
  if (name.length > 64 || name.contains(RegExp(r'[\s]'))) {
    throw FormatException('invalid channel name: $input');
  }
  return name;
}

/// Parses `@name` mentions out of message text: an `@` followed by a
/// run of name characters (`[A-Za-z0-9_.-]`), not inside a longer word
/// (emails and interior at-signs do not mention). Case is preserved;
/// duplicates collapse to first appearance. This is deliberately
/// simple and testable — no routing this round.
List<String> parseMentions(String text) {
  final mentions = <String>[];
  final pattern = RegExp(r'(?:^|[^A-Za-z0-9_.-])@([A-Za-z0-9_.-]+)');
  for (final match in pattern.allMatches(text)) {
    final name = match.group(1)!;
    if (!mentions.contains(name)) mentions.add(name);
  }
  return mentions;
}

/// The result of a compaction: what the room's view now starts from.
final class ChannelCompaction {
  const ChannelCompaction({
    required this.channel,
    required this.point,
    required this.digested,
    required this.digestId,
    this.superseded = const [],
  });

  /// The compacted channel.
  final String channel;

  /// The compaction point: reads return only rows with ids past it.
  /// Zero means no compaction.
  final int point;

  /// How many messages the compaction superseded (cleared channels
  /// report every prior message).
  final int digested;

  /// The digest system message's id, zero when [clear] produced no
  /// digest row.
  final int digestId;

  /// The superseded rows, oldest first — everything the compaction
  /// removed from the view. The database keeps them; this copy exists
  /// for the future memory-extraction hook (issue 94), which will
  /// distill durable lessons from exactly this span.
  final List<ChannelMessage> superseded;

  @override
  String toString() =>
      'compaction($channel point=$point digested=$digested '
      'digest=#$digestId)';
}

/// The store surface the channel tools, CLI and TUI pane use. One
/// store owns one file. Messages are append-only; [setMember] is the
/// only mutating presence operation and it also announces itself as a
/// `status` message so history explains presence changes. [compact]
/// is the one view-shaping operation: it never edits or deletes rows —
/// it records a compaction point (and, for `compact`, appends a digest
/// system message) and every read simply stops returning superseded
/// messages. The database stays a complete audit trail.
abstract interface class ChannelStoreApi {
  /// The store file's path (store-native string; `:memory:` in tests).
  String get file;

  /// Create the channel if missing. Idempotent; concurrent creators
  /// race harmlessly. `#lobby` exists from the first open.
  void ensureChannel(String name);

  /// Every channel with its message and member counts, by name.
  List<ChannelSummary> listChannels();

  /// Append one message. The channel is created when missing (posting
  /// joins). Returns the stored row, database id filled in.
  ChannelMessage post(String channel, {
    required String sender,
    required String text,
    ChannelMessageType type = ChannelMessageType.message,
    List<String>? mentions,
    int? replyTo,
  });

  /// The most recent [limit] messages strictly after the cursor
  /// ([sinceId] wins when both are given), oldest first. The tail
  /// window — the last `limit` rows — is what a catch-up read wants.
  List<ChannelMessage> read(String channel,
      {int? sinceId, DateTime? sinceTime, int limit = 50});

  /// One message by id, when it sits in [channel]; null otherwise.
  /// Reply validation and rendering use this.
  ChannelMessage? message(String channel, int id);

  /// Upsert a member's presence. With [announce] (the default) the
  /// change is also appended as a `status` message so scrollback shows
  /// joins and status changes in place.
  void setMember(String channel, String member,
      {required String status, String? role, String? summary,
      bool announce = true});

  /// The channel's members, by name.
  List<ChannelMember> members(String channel);

  /// The channel's highest message id, 0 when empty — the unread
  /// cursor for polling readers.
  int lastMessageId(String channel);

  /// Compact the channel's VIEW: keep the most recent [keep] messages
  /// plus (unless [clear]) one `system` digest message authored by
  /// [actor] that names the superseded span and its key points; every
  /// read from then on returns only the digest and the retained tail.
  /// Rows are never deleted — the log stays auditable, the room's view
  /// is what shrinks. [clear] keeps nothing and writes no digest: a
  /// compaction point at the newest id. The channel keeps its identity,
  /// membership and name either way.
  ///
  /// Returns what the compaction did, for the caller's bookkeeping
  /// (and for the future memory-extraction hook: issue 94).
  ChannelCompaction compact(String channel,
      {required String actor, int keep = compactDefaultKeep, bool clear = false});

  /// The channel's compaction point: 0 when the view was never
  /// compacted. Reads return only rows past it.
  int compactionPoint(String channel);

  /// Release the store's resources.
  void close();
}

/// Opens a session's chat store: the injection point an assembly
/// passes to the tools plugin and the TUI pane. A chat belongs to one
/// session — the id the host already gave it — so the opener receives
/// that id and returns the store scoped to it. Subagent children open
/// their parent's scope, never their own session id.
typedef ChannelStoreOpener = ChannelStoreApi Function(String chatSessionId);

/// The store file for one session's chat:
/// `.tina/channels/<session-id>.db` (that directory is already
/// gitignored). Session ids are filesystem-safe by construction;
/// anything exotic maps onto `[A-Za-z0-9._-]`.
String defaultChannelStorePath(String workspace, String sessionId) =>
    p.join(workspace, '.tina', 'channels', '${_chatScopeName(sessionId)}.db');

String _chatScopeName(String sessionId) {
  final cleaned = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  return cleaned.isEmpty ? 'session' : cleaned;
}
