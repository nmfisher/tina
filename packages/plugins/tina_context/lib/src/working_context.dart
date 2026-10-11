import 'dart:convert';

import 'package:tina_engine_2/tina_engine_2.dart';

const contextPluginId = 'tina/context';
const workingContextKey = 'working_context';

/// A detached, immutable message list, including nested tool inputs.
List<Message> freezeMessages(Iterable<Message> messages) {
  final payload = PluginStateEntry.snapshot(
    pluginId: contextPluginId,
    stateKey: workingContextKey,
    schemaVersion: 1,
    value: {
      'messages': [for (final m in messages) m.toJson()]
    },
  ).value!;
  return List.unmodifiable([
    for (final raw in payload['messages'] as List)
      _freezeMessage(Message.fromJson(Map<String, dynamic>.from(raw as Map))),
  ]);
}

Message _freezeMessage(Message m) => Message(
      role: m.role,
      content: List.unmodifiable(m.content.map((b) => switch (b) {
            ToolUseBlock() => ToolUseBlock(
                id: b.id,
                name: b.name,
                input: Map.unmodifiable(b.input),
                argumentsParseError: b.argumentsParseError),
            ToolResultBlock() => ToolResultBlock(
                toolUseId: b.toolUseId,
                content: b.content,
                isError: b.isError,
                images: List.unmodifiable(b.images)),
            _ => b,
          })),
      reasoning: List.unmodifiable(m.reasoning),
      isSynthetic: m.isSynthetic,
    );

final class WorkingContext {
  WorkingContext({
    required this.revision,
    required this.throughSeq,
    required Iterable<Message> messages,
  }) : messages = freezeMessages(messages);

  final int revision;

  /// Last log entry incorporated, including non-message entries. -1 is empty.
  final int throughSeq;
  final List<Message> messages;
}

final class WorkingContextSnapshot {
  WorkingContextSnapshot({
    required this.revision,
    required this.throughSeq,
    required this.originTurnId,
    required Iterable<Message> messages,
  }) : messages = freezeMessages(messages) {
    if (revision < 1 || throughSeq < -1) {
      throw const FormatException('Invalid working-context counters');
    }
    validateContextMessages(this.messages);
  }

  final int revision;
  final int throughSeq;
  final String? originTurnId;
  final List<Message> messages;

  PluginStateEntry toEntry() => PluginStateEntry.snapshot(
        pluginId: contextPluginId,
        stateKey: workingContextKey,
        schemaVersion: 1,
        value: {
          'revision': revision,
          'through_seq': throughSeq,
          'origin_turn_id': originTurnId,
          'messages': [for (final m in messages) m.toJson()],
        },
      );

  factory WorkingContextSnapshot.fromEntry(PluginStateEntry entry) {
    if (entry.pluginId != contextPluginId ||
        entry.stateKey != workingContextKey ||
        entry.schemaVersion != 1 ||
        entry.value == null) {
      throw const FormatException('Unsupported working-context snapshot');
    }
    final v = entry.value!;
    return WorkingContextSnapshot(
      revision: v['revision'] as int,
      throughSeq: v['through_seq'] as int,
      originTurnId: v['origin_turn_id'] as String?,
      messages: [
        for (final raw in v['messages'] as List)
          Message.fromJson(Map<String, dynamic>.from(raw as Map)),
      ],
    );
  }
}

/// Provider-neutral validation. Entire historical tool exchanges may be
/// removed; retained exchanges must keep their original call/result pairing.
void validateContextMessages(List<Message> messages) {
  final seen = <String>{};
  final pending = <String>{};
  for (final m in messages) {
    if (m.content.isEmpty && !m.isReasoningOnly) {
      throw const FormatException('Empty context message');
    }
    final calls = m.content.whereType<ToolUseBlock>().toList();
    final results = m.content.whereType<ToolResultBlock>().toList();
    if (results.isNotEmpty) {
      if (m.role != Role.user || results.length != m.content.length) {
        throw const FormatException('Invalid tool-result message');
      }
      for (final result in results) {
        if (!pending.remove(result.toolUseId)) {
          throw const FormatException('Unpaired or duplicate tool result');
        }
      }
    } else {
      if (pending.isNotEmpty) {
        throw const FormatException('Missing tool results');
      }
      if (calls.isNotEmpty && m.role != Role.assistant) {
        throw const FormatException('Tool calls require assistant role');
      }
      for (final call in calls) {
        if (call.id.isEmpty || !seen.add(call.id)) {
          throw const FormatException('Invalid or duplicate tool call id');
        }
        pending.add(call.id);
      }
    }
  }
  if (pending.isNotEmpty) throw const FormatException('Missing tool results');
}

bool sameMessages(Iterable<Message> a, Iterable<Message> b) =>
    jsonEncode([for (final m in a) m.toJson()]) ==
    jsonEncode([for (final m in b) m.toJson()]);

/// Phase 1 of [deriveWorkingContext]: what the turn ledger says.
///
/// One scan over the log collects everything the later phases need to
/// decide which entries count: which turns completed, which are still
/// open, and where the last clear sits. Sequence continuity is checked
/// here, once, so a gap fails before any snapshot or message work.
final class TurnLedger {
  const TurnLedger._(this.completedTurns, this.openTurns, this.clearedAt);

  /// The single scan. Throws [FormatException] on a sequence gap.
  factory TurnLedger.scan(List<SessionEntry> log) {
    final completed = <String>{};
    final open = <String>[];
    var clearedAt = -1;
    for (var i = 0; i < log.length; i++) {
      final e = log[i];
      if (e.seq != i) throw const FormatException('Session sequence gap');
      if (e is TurnStartedEntry) open.add(e.turnId);
      if (e is TurnEndedEntry) {
        completed.add(e.turnId);
        open.remove(e.turnId);
      }
      if (e is ContextClearedEntry) {
        clearedAt = e.seq;
        open.clear();
      }
    }
    return TurnLedger._(completed, open, clearedAt);
  }

  /// Turns whose [TurnEndedEntry] is in the log.
  final Set<String> completedTurns;

  /// Turns started but never ended, in start order. The last one is the
  /// pending turn a resume would replay ([pendingTurnId]).
  final List<String> openTurns;

  /// Seq of the last [ContextClearedEntry], -1 when the log never clears.
  final int clearedAt;

  /// The most recent open turn, or null when every started turn ended.
  String? get pendingTurnId => openTurns.isEmpty ? null : openTurns.last;

  /// Whether content attached to [turnId] belongs in the working context:
  /// unattributed content always counts; attributed content counts when
  /// its turn completed or when it is [activeTurn] — the one turn the
  /// include-pending policy keeps live (null: none is).
  bool isEligible(String? turnId, {required String? activeTurn}) =>
      turnId == null ||
      completedTurns.contains(turnId) ||
      turnId == activeTurn;
}

/// Phase 2 of [deriveWorkingContext]: which snapshot, if any, is live.
///
/// Walks the working-context entries in log order and validates the whole
/// history, not just the winner: throughSeq chains entry-by-entry,
/// revisions increase monotonically, and each snapshot's origin turn must
/// own the pending turn of the log prefix it snapshotted. A snapshot is
/// live when it sits after the last clear and is turn-eligible; entries
/// that fail only the liveness test still count for the revision
/// watermark — a superseded editor retains credit for its revision.
final class SnapshotFold {
  const SnapshotFold._(this.live, this.maxRevision);

  /// The fold. [ledger] provides clearedAt; [activeTurn] is the
  /// include-pending policy's one live turn (null: only completed turns).
  static SnapshotFold resolve(
    List<SessionEntry> log,
    TurnLedger ledger, {
    required String? activeTurn,
  }) {
    WorkingContextSnapshot? live;
    var maxRevision = 0;
    for (final e in log.whereType<PluginStateEntry>()) {
      if (e.pluginId != contextPluginId || e.stateKey != workingContextKey) {
        continue;
      }
      final candidate = WorkingContextSnapshot.fromEntry(e);
      if (candidate.throughSeq != e.seq - 1 ||
          candidate.revision <= maxRevision) {
        throw const FormatException('Invalid working-context snapshot history');
      }
      final prefix = deriveSession(log.sublist(0, e.seq),
          const SessionSettings(),
          includePendingTurn: true);
      if (candidate.originTurnId != null &&
          candidate.originTurnId != prefix.pendingTurnId) {
        throw const FormatException('Invalid working-context turn ownership');
      }
      maxRevision = candidate.revision;
      if (e.seq > ledger.clearedAt &&
          ledger.isEligible(candidate.originTurnId, activeTurn: activeTurn)) {
        live = candidate;
      }
    }
    return SnapshotFold._(live, maxRevision);
  }

  /// The snapshot the working context builds on, null for full replay.
  final WorkingContextSnapshot? live;

  /// Highest revision seen anywhere in the history, live or not.
  final int maxRevision;
}

/// Phase 3 of [deriveWorkingContext]: the message list itself.
///
/// With no live snapshot the core derivation answers for the whole log —
/// compaction included. With one, the snapshot's messages are the base
/// and only eligible tail appends are incorporated, exactly once: the
/// snapshot already contains everything through its throughSeq. A
/// compaction after the edit refuses to splice rather than guessing
/// positions the snapshot's message list cannot express.
List<Message> assembleContextMessages(
  List<SessionEntry> log, {
  required TurnLedger ledger,
  required WorkingContextSnapshot? snapshot,
  required String? activeTurn,
  required bool includePendingTurn,
}) {
  if (snapshot == null) {
    return deriveSession(log, const SessionSettings(),
            includePendingTurn: includePendingTurn)
        .messages;
  }
  final messages = [...snapshot.messages];
  for (final e in log.skip(snapshot.throughSeq + 1)) {
    if (e is MessageAppendedEntry &&
        ledger.isEligible(e.turnId, activeTurn: activeTurn)) {
      messages.add(e.message);
    }
    if (e is CompactedEntry) {
      throw StateError('Compaction cannot follow a working-context edit');
    }
  }
  return messages;
}

/// Pure replay. A snapshot from an abandoned turn is never used on resume.
/// With includePendingTurn, only the latest open turn is considered live.
///
/// Three phases, each pure and tested on its own:
/// [TurnLedger.scan] reads the turn structure once,
/// [SnapshotFold.resolve] validates the edit history and picks the live
/// snapshot, [assembleContextMessages] produces the message list.
WorkingContext deriveWorkingContext(
  List<SessionEntry> log, {
  bool includePendingTurn = false,
}) {
  final ledger = TurnLedger.scan(log);
  final activeTurn = includePendingTurn && ledger.openTurns.isNotEmpty
      ? ledger.openTurns.last
      : null;
  final snapshots =
      SnapshotFold.resolve(log, ledger, activeTurn: activeTurn);
  final messages = assembleContextMessages(log,
      ledger: ledger,
      snapshot: snapshots.live,
      activeTurn: activeTurn,
      includePendingTurn: includePendingTurn);
  return WorkingContext(
      revision: snapshots.maxRevision,
      throughSeq: log.length - 1,
      messages: messages);
}
