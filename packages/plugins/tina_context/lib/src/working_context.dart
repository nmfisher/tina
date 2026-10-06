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

/// Pure replay. A snapshot from an abandoned turn is never used on resume.
/// With includePendingTurn, only the latest open turn is considered live.
WorkingContext deriveWorkingContext(
  List<SessionEntry> log, {
  bool includePendingTurn = false,
}) {
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
  final active = includePendingTurn && open.isNotEmpty ? open.last : null;
  bool eligible(String? id) =>
      id == null || completed.contains(id) || id == active;
  WorkingContextSnapshot? snapshot;
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
    final prefix = deriveSession(log.sublist(0, e.seq), const SessionSettings(),
        includePendingTurn: true);
    if (candidate.originTurnId != null &&
        candidate.originTurnId != prefix.pendingTurnId) {
      throw const FormatException('Invalid working-context turn ownership');
    }
    maxRevision = candidate.revision;
    if (e.seq > clearedAt && eligible(candidate.originTurnId)) {
      snapshot = candidate;
    }
  }
  final List<Message> messages;
  if (snapshot == null) {
    messages = deriveSession(log, const SessionSettings(),
            includePendingTurn: includePendingTurn)
        .messages;
  } else {
    messages = [...snapshot.messages];
    for (final e in log.skip(snapshot.throughSeq + 1)) {
      if (e is MessageAppendedEntry && eligible(e.turnId)) {
        messages.add(e.message);
      }
      if (e is CompactedEntry) {
        throw StateError('Compaction cannot follow a working-context edit');
      }
    }
  }
  return WorkingContext(
      revision: maxRevision, throughSeq: log.length - 1, messages: messages);
}
