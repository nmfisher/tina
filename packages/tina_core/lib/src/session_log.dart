/// The session log's entry types and the one derive function.
///
/// The log is append-only and the loop is its only writer; every fact the
/// session needs later lives in one of the cases below. The rule for
/// whether a fact needs an entry: if a plugin's effect can be recomputed
/// from the log plus session settings, no entry — if it cannot, append
/// one. That is why the raw input is always recorded (no derivation can
/// reproduce the words as typed) and why a plugin rewrite, a mode flip
/// and a compaction each get their own entry (the plugin's rule, the
/// operator's hand and the dropped text are all unrecoverable).
///
/// `seq` equals the entry's position in the log. A gap means corruption;
/// deletion is impossible by construction — the store appends only.
///
/// Every entry round-trips through JSON as one object, so a JSON Lines
/// file and the SQLite entry log write the same bytes.
library;

import 'dart:convert';

import 'message.dart';
import 'stream.dart';
import 'plugin_id.dart';

/// Why a turn stopped. The loop's stop vocabulary, owned here so an
/// entry can carry it without the core depending on a loop package.
enum TurnStopReason { complete, cancelled, error }

/// What the providers reported using, as recorded on a [TurnEndedEntry].
/// Shaped so `TokenUsage` converts losslessly and sums additively.
final class EntryUsage {
  final int inputTokens;
  final int outputTokens;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;

  const EntryUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
  });

  factory EntryUsage.fromTokens(TokenUsage u) => EntryUsage(
        inputTokens: u.inputTokens,
        outputTokens: u.outputTokens,
        cacheCreationInputTokens: u.cacheCreationInputTokens,
        cacheReadInputTokens: u.cacheReadInputTokens,
      );

  EntryUsage operator +(EntryUsage other) => EntryUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cacheCreationInputTokens:
            cacheCreationInputTokens + other.cacheCreationInputTokens,
        cacheReadInputTokens: cacheReadInputTokens + other.cacheReadInputTokens,
      );

  Map<String, dynamic> toJson() => {
        'input': inputTokens,
        'output': outputTokens,
        'cache_write': cacheCreationInputTokens,
        'cache_read': cacheReadInputTokens,
      };

  factory EntryUsage.fromJson(Map<String, dynamic> j) => EntryUsage(
        inputTokens: (j['input'] as num?)?.toInt() ?? 0,
        outputTokens: (j['output'] as num?)?.toInt() ?? 0,
        cacheCreationInputTokens: (j['cache_write'] as num?)?.toInt() ?? 0,
        cacheReadInputTokens: (j['cache_read'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is EntryUsage &&
      inputTokens == other.inputTokens &&
      outputTokens == other.outputTokens &&
      cacheCreationInputTokens == other.cacheCreationInputTokens &&
      cacheReadInputTokens == other.cacheReadInputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens,
      cacheCreationInputTokens, cacheReadInputTokens);

  @override
  String toString() => 'EntryUsage(in $inputTokens, out $outputTokens)';
}

/// One entry in the session log. Sealed: the case set below is the whole
/// set, and a reader switches over it exhaustively.
/// Opaque, versioned whole-state snapshot belonging to one plugin/key.
/// Payload interpretation belongs to the owner. Null is an explicit tombstone.
abstract class PluginStateEntry extends SessionEntry {
  const PluginStateEntry({super.seq});
  factory PluginStateEntry.snapshot(
      {required String pluginId,
      required String stateKey,
      required int schemaVersion,
      required Map<String, dynamic>? value,
      String at = '',
      int seq = 0}) {
    validatePluginId(pluginId);
    if (!RegExp(r'^[a-z][a-z0-9_/-]*$').hasMatch(stateKey) ||
        schemaVersion < 1 ||
        seq < 0) {
      throw const FormatException('Invalid plugin-state envelope');
    }
    final frozen = _freezeJson(value);
    return _PluginSnapshot(pluginId, stateKey, schemaVersion,
        frozen as Map<String, dynamic>?, at, seq);
  }
  String get pluginId;
  String get stateKey;
  int get schemaVersion;
  Map<String, dynamic>? get value;
  String get at;
  @override
  String get kind => 'plugin_state';
  @override
  PluginStateEntry withSeq(int seq) => PluginStateEntry.snapshot(
      pluginId: pluginId,
      stateKey: stateKey,
      schemaVersion: schemaVersion,
      value: value,
      at: at,
      seq: seq);
  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'plugin_id': pluginId,
        'state_key': stateKey,
        'schema_version': schemaVersion,
        'value': value,
        if (at.isNotEmpty) 'at': at
      };
}

Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is bool || value is int)
    return value;
  if (value is double && value.isFinite) return value;
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeJson));
  if (value is Map && value.keys.every((k) => k is String)) {
    return Map<String, dynamic>.unmodifiable(
        {for (final e in value.entries) e.key as String: _freezeJson(e.value)});
  }
  throw const FormatException('Plugin state must contain only JSON values');
}

final class _PluginSnapshot extends PluginStateEntry {
  const _PluginSnapshot(this.pluginId, this.stateKey, this.schemaVersion,
      this.value, this.at, int seq)
      : super(seq: seq);
  @override
  final String pluginId, stateKey, at;
  @override
  final int schemaVersion;
  @override
  final Map<String, dynamic>? value;
  @override
  bool operator ==(Object other) =>
      other is PluginStateEntry &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

sealed class SessionEntry {
  const SessionEntry({this.seq = 0});

  /// The entry's position in the log. Set by the loop's single write
  /// path ([withSeq]); zero until then. Because it travels in the
  /// payload, a decoded row and the log it came from agree — a reader
  /// checking `seq == index` over a store's rows detects a gap without
  /// touching the store's own counters.
  final int seq;

  /// This case's JSON discriminator.
  String get kind;

  /// This entry with its position stamped. The loop's write path calls
  /// this once per entry; [fromJson] calls it once per decoded row.
  SessionEntry withSeq(int seq);

  /// One JSON object — the payload a store row or a JSON Lines line
  /// holds, verbatim. Carries `seq` when stamped.
  Map<String, dynamic> toJson() => {'type': kind, if (seq > 0) 'seq': seq};

  /// The entry a decoded payload named, position stamped from the
  /// payload's `seq`. An unknown `type` throws — a log this code cannot
  /// read must not be silently skimmed.
  static SessionEntry fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String?;
    final at = (j['at'] as String?) ?? '';
    final stamped = (j['seq'] as num?)?.toInt() ?? 0;
    switch (type) {
      case 'plugin_state':
        if (j['schema_version'] is! int ||
            !j.containsKey('value') ||
            (j['seq'] != null && j['seq'] is! int))
          throw const FormatException('Invalid plugin-state envelope');
        return PluginStateEntry.snapshot(
            pluginId: j['plugin_id'] as String,
            stateKey: j['state_key'] as String,
            schemaVersion: j['schema_version'] as int,
            value: j['value'] == null
                ? null
                : Map<String, dynamic>.from(j['value'] as Map),
            at: at,
            seq: stamped);
      case TurnStartedEntry.kindName:
        return TurnStartedEntry(turnId: j['turn_id'] as String, at: at)
            .withSeq(stamped);
      case InputRecordedEntry.kindName:
        return InputRecordedEntry(
                turnId: j['turn_id'] as String,
                text: j['text'] as String,
                at: at)
            .withSeq(stamped);
      case InputRewrittenEntry.kindName:
        return InputRewrittenEntry(
          turnId: j['turn_id'] as String,
          pluginId: j['plugin_id'] as String,
          text: j['text'] as String,
          at: at,
        ).withSeq(stamped);
      case MessageAppendedEntry.kindName:
        return MessageAppendedEntry(
          turnId: j['turn_id'] as String,
          message:
              Message.fromJson(Map<String, dynamic>.from(j['message'] as Map)),
          at: at,
        ).withSeq(stamped);
      case TurnEndedEntry.kindName:
        return TurnEndedEntry(
          turnId: j['turn_id'] as String,
          reason: TurnStopReason.values.byName(j['reason'] as String),
          usage: EntryUsage.fromJson(
              Map<String, dynamic>.from(j['usage'] as Map? ?? const {})),
          stop: j['stop'] == null
              ? null
              : Map<String, dynamic>.from(j['stop'] as Map),
          at: at,
        ).withSeq(stamped);
      case UsageRecordedEntry.kindName:
        return UsageRecordedEntry(
          turnId: j['turn_id'] as String,
          usage:
              EntryUsage.fromJson(Map<String, dynamic>.from(j['usage'] as Map)),
          estimatedTokens: (j['estimated_tokens'] as num?)?.toInt() ?? 0,
          child: j['child'] == true,
          at: at,
          seq: stamped,
        );
      case CompactedEntry.kindName:
        return CompactedEntry(
          replacedFrom: (j['replaced_from'] as num).toInt(),
          replacedTo: (j['replaced_to'] as num).toInt(),
          summary: j['summary'] as String,
          at: at,
        ).withSeq(stamped);
      default:
        throw FormatException('Unknown session entry type: $type');
    }
  }
}

/// A turn began. The boundary the derive function snaps to.
final class TurnStartedEntry extends SessionEntry {
  static const kindName = 'turn_started';

  /// The turn's id — the loop's `Input.id`.
  final String turnId;

  /// When the turn started, ISO-8601 UTC. Recorded, never derived from.
  final String at;

  const TurnStartedEntry({required this.turnId, this.at = '', super.seq = 0});

  @override
  TurnStartedEntry withSeq(int newSeq) =>
      TurnStartedEntry(turnId: turnId, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() =>
      {...super.toJson(), 'turn_id': turnId, if (at.isNotEmpty) 'at': at};

  @override
  bool operator ==(Object other) =>
      other is TurnStartedEntry && turnId == other.turnId && at == other.at;

  @override
  int get hashCode => Object.hash(kindName, turnId, at);

  @override
  String toString() => 'TurnStarted($turnId)';
}

/// The human's input, exactly as typed, before any plugin touched it.
/// Always recorded — the raw words are the one thing no derivation can
/// reproduce later.
final class InputRecordedEntry extends SessionEntry {
  static const kindName = 'input_recorded';

  final String turnId;

  /// The input as typed.
  final String text;

  final String at;

  const InputRecordedEntry({
    required this.turnId,
    required this.text,
    this.at = '',
    super.seq = 0,
  });

  @override
  InputRecordedEntry withSeq(int newSeq) =>
      InputRecordedEntry(turnId: turnId, text: text, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'text': text,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is InputRecordedEntry &&
      turnId == other.turnId &&
      text == other.text &&
      at == other.at;

  @override
  int get hashCode => Object.hash(kindName, turnId, text, at);

  @override
  String toString() => 'InputRecorded($turnId, "$text")';
}

/// A plugin replaced the input. A rewrite cannot be recomputed — the
/// plugin's rule is its own — so it gets this entry, naming the plugin.
/// The message the provider eventually sees carries the rewritten text;
/// the raw words stay in [InputRecordedEntry].
final class InputRewrittenEntry extends SessionEntry {
  static const kindName = 'input_rewritten';

  final String turnId;

  /// The plugin that did the rewriting.
  final String pluginId;

  /// The input after the rewrite.
  final String text;

  final String at;

  const InputRewrittenEntry({
    required this.turnId,
    required this.pluginId,
    required this.text,
    this.at = '',
    super.seq = 0,
  });

  @override
  InputRewrittenEntry withSeq(int newSeq) => InputRewrittenEntry(
      turnId: turnId, pluginId: pluginId, text: text, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'plugin_id': pluginId,
        'text': text,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is InputRewrittenEntry &&
      turnId == other.turnId &&
      pluginId == other.pluginId &&
      text == other.text &&
      at == other.at;

  @override
  int get hashCode => Object.hash(kindName, turnId, pluginId, text, at);

  @override
  String toString() => 'InputRewritten($turnId, by $pluginId, "$text")';
}

/// One message entered the conversation — the user input as the turn
/// finally took it (rewrites included), the model's replies, and the
/// paired tool results. This is the log's only transcript content:
/// derive walks these.
final class MessageAppendedEntry extends SessionEntry {
  static const kindName = 'message_appended';

  /// The turn the message belongs to.
  final String turnId;

  /// The message, in the core's own JSON shape — the same bytes the
  /// wire and any older transcript already use.
  final Message message;

  final String at;

  const MessageAppendedEntry({
    required this.turnId,
    required this.message,
    this.at = '',
    super.seq = 0,
  });

  @override
  MessageAppendedEntry withSeq(int newSeq) => MessageAppendedEntry(
      turnId: turnId, message: message, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'message': message.toJson(),
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is MessageAppendedEntry &&
      turnId == other.turnId &&
      at == other.at &&
      message.role == other.message.role &&
      message.isSynthetic == other.message.isSynthetic &&
      _blocksEqual(message.content, other.message.content);

  static bool _blocksEqual(List<ContentBlock> a, List<ContentBlock> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (jsonEncode(a[i].toJson()) != jsonEncode(b[i].toJson())) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(kindName, turnId, at);

  @override
  String toString() =>
      'MessageAppended($turnId, ${message.role}, ${message.content.length} blocks)';
}

/// A turn ended: why, and what the providers reported using across the
/// turn's requests — the session-level number a spend view reads.
final class TurnEndedEntry extends SessionEntry {
  static const kindName = 'turn_ended';

  final String turnId;

  final TurnStopReason reason;

  final EntryUsage usage;

  final String at;

  /// Optional plugin termination metadata. Older readers ignore this field;
  /// the wire reason remains cancelled for backward compatibility.
  final Map<String, dynamic>? stop;

  const TurnEndedEntry({
    required this.turnId,
    required this.reason,
    this.usage = const EntryUsage(),
    this.at = '',
    this.stop,
    super.seq = 0,
  });

  @override
  TurnEndedEntry withSeq(int newSeq) => TurnEndedEntry(
      turnId: turnId,
      reason: reason,
      usage: usage,
      at: at,
      stop: stop,
      seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'reason': reason.name,
        'usage': usage.toJson(),
        if (stop != null) 'stop': stop,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is TurnEndedEntry &&
      turnId == other.turnId &&
      reason == other.reason &&
      usage == other.usage &&
      at == other.at &&
      jsonEncode(stop) == jsonEncode(other.stop);

  @override
  int get hashCode =>
      Object.hash(kindName, turnId, reason, usage, at, jsonEncode(stop));

  @override
  String toString() => 'TurnEnded($turnId, ${reason.name})';
}

/// One settled provider attempt. Accounting is separate from the transcript:
/// retries, cancellations and children may spend tokens without a reply.
/// Provider plugins record these through the loop's single writer.
final class UsageRecordedEntry extends SessionEntry {
  static const kindName = 'usage_recorded';
  const UsageRecordedEntry(
      {required this.turnId,
      this.usage = const EntryUsage(),
      this.estimatedTokens = 0,
      this.child = false,
      this.at = '',
      super.seq});
  final String turnId;
  final EntryUsage usage;
  final int estimatedTokens;
  final bool child;
  final String at;
  @override
  String get kind => kindName;
  @override
  UsageRecordedEntry withSeq(int seq) => UsageRecordedEntry(
      turnId: turnId,
      usage: usage,
      estimatedTokens: estimatedTokens,
      child: child,
      at: at,
      seq: seq);
  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'usage': usage.toJson(),
        'estimated_tokens': estimatedTokens,
        'child': child,
        if (at.isNotEmpty) 'at': at
      };
  @override
  bool operator ==(Object other) =>
      other is UsageRecordedEntry &&
      turnId == other.turnId &&
      usage == other.usage &&
      estimatedTokens == other.estimatedTokens &&
      child == other.child &&
      at == other.at;
  @override
  int get hashCode =>
      Object.hash(kindName, turnId, usage, estimatedTokens, child, at);
}

/// History was compacted: derived-message positions [replacedFrom]..
/// [replacedTo] (inclusive; indexes into the derived message list **as
/// it stood when this entry was appended** — a log is replayed in order,
/// so an earlier compaction's shrinkage is already applied) are gone,
/// replaced by one synthetic user message carrying [summary]. The
/// dropped text is unrecoverable, which is exactly why this entry
/// exists: it is the one fact no derivation can reproduce.
final class CompactedEntry extends SessionEntry {
  static const kindName = 'compacted';

  /// First replaced message index.
  final int replacedFrom;

  /// Last replaced message index, inclusive.
  final int replacedTo;

  /// The summary text standing in for the replaced range.
  final String summary;

  final String at;

  const CompactedEntry({
    required this.replacedFrom,
    required this.replacedTo,
    required this.summary,
    this.at = '',
    super.seq = 0,
  });

  @override
  CompactedEntry withSeq(int newSeq) => CompactedEntry(
      replacedFrom: replacedFrom,
      replacedTo: replacedTo,
      summary: summary,
      at: at,
      seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'replaced_from': replacedFrom,
        'replaced_to': replacedTo,
        'summary': summary,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is CompactedEntry &&
      replacedFrom == other.replacedFrom &&
      replacedTo == other.replacedTo &&
      summary == other.summary &&
      at == other.at;

  @override
  int get hashCode =>
      Object.hash(kindName, replacedFrom, replacedTo, summary, at);

  @override
  String toString() =>
      'Compacted($replacedFrom..$replacedTo, ${summary.length} chars)';
}

/// The per-session settings derive consults. Plain strings — the core
/// owns no mode vocabulary and no prompt text. A session restarts these;
/// the log does not carry them.
final class SessionSettings {
  final String systemPrompt;
  const SessionSettings({this.systemPrompt = ''});
  Map<String, dynamic> toJson() => {'system_prompt': systemPrompt};
  factory SessionSettings.fromJson(Map<String, dynamic> j) =>
      SessionSettings(systemPrompt: j['system_prompt'] as String? ?? '');
  @override
  bool operator ==(Object other) =>
      other is SessionSettings && systemPrompt == other.systemPrompt;
  @override
  int get hashCode => systemPrompt.hashCode;
}

/// What derive produced: the request-shaped view of the log.
final class DerivedSession {
  const DerivedSession(
      {required this.messages,
      required this.systemPrompt,
      required this.entriesConsumed,
      this.pendingTurnId,
      this.pluginStates = const {}});
  final List<Message> messages;
  final String systemPrompt;
  final int entriesConsumed;
  final String? pendingTurnId;
  final Map<String, Map<String, PluginStateEntry>> pluginStates;
}

/// Log + settings in, request out. Pure: the same log and the same
/// settings give the same result — which is what makes a store a cache
/// of this function rather than a second truth.
///
/// The snap rule: the derived conversation ends at a turn boundary. A
/// turn that started but never ended — its [TurnEndedEntry] is not in the
/// log — contributes nothing to [DerivedSession.messages] when
/// [includePendingTurn] is false (the default): its input, rewrite and
/// messages belong to the unfinished turn, and a resume replays the turn
/// from its input instead of half-sending it. The unfinished turn's id
/// comes back as [DerivedSession.pendingTurnId] either way.
///
/// [includePendingTurn] is for the loop that *is* the writer: mid-turn,
/// the messages of the turn it is writing — the **last** open turn — are
/// exactly what the next request must carry, so that turn's slots stay
/// in. Older open turns stay out in both modes: an abandoned turn is
/// replayed from its recorded input, never half-sent.
///
/// Compaction: each [CompactedEntry] is applied in log order to the
/// message list as it stands at that point — replace positions
/// [replacedFrom, replacedTo] with the summary as one synthetic user
/// message. A summary inherits "belongs to a completed turn" from the
/// replaced range, so a summary over completed history survives the snap
/// rule, and the boundary rule still holds: compaction happens between
/// turns, and a summary is never asked to stand in for a half turn.
DerivedSession deriveSession(
  List<SessionEntry> log,
  SessionSettings settings, {
  bool includePendingTurn = false,
}) {
  // The message slots, in log order. A slot remembers the turn that was
  // in flight when it was appended; the completed-turn set decides what
  // survives the snap.
  final slots = <_Slot>[];
  final systemPrompt = settings.systemPrompt;
  final completedTurns = <String>{};
  final openTurns = <String>[];

  final states = <String, Map<String, PluginStateEntry>>{};

  for (final e in log) {
    switch (e) {
      case TurnStartedEntry(:final turnId):
        openTurns.add(turnId);
      case InputRecordedEntry() ||
            InputRewrittenEntry() ||
            UsageRecordedEntry():
        break; // audit trail; the message entries carry the transcript
      case MessageAppendedEntry():
        slots.add(_Slot(e.message, e.turnId));
      case TurnEndedEntry(:final turnId):
        completedTurns.add(turnId);
        openTurns.remove(turnId);
      case CompactedEntry(
          :final replacedFrom,
          :final replacedTo,
          :final summary
        ):
        _compact(slots, replacedFrom, replacedTo, summary);
      case PluginStateEntry():
        (states[e.pluginId] ??= {})[e.stateKey] = e;
    }
  }
  // A turn that started but never ended — a crash mid-turn, or an
  // abandoned one — is the resume's replay target; the most recent such
  // turn is the one a resume would continue.
  final pendingTurnId = openTurns.isEmpty ? null : openTurns.last;

  final writingTurnId = openTurns.isEmpty ? null : openTurns.last;
  final messages = [
    for (final s in slots)
      if (completedTurns.contains(s.turnId) ||
          (includePendingTurn && s.turnId == writingTurnId))
        s.message,
  ];

  return DerivedSession(
    messages: messages,
    systemPrompt: systemPrompt,
    entriesConsumed: log.length,
    pendingTurnId: pendingTurnId,
    pluginStates: Map.unmodifiable({
      for (final entry in states.entries)
        entry.key: Map<String, PluginStateEntry>.unmodifiable(entry.value)
    }),
  );
}

class _Slot {
  _Slot(this.message, this.turnId);

  Message message;

  /// The turn the message was appended under.
  String turnId;
}

/// Replace slots [from]..[to] (inclusive, into the list as it stands
/// now) with one summary slot. The summary's turn id — the thing the
/// snap rule filters on — is borrowed from the replaced range: any
/// replaced slot from a completed turn makes the summary survive; a
/// summary over nothing survives if every replaced slot survived. An
/// out-of-range compaction touches nothing (a log claiming to replace
/// history that is not there is corruption; derive stays pure and simply
/// does not invent deletions).
void _compact(List<_Slot> slots, int from, int to, String summary) {
  if (from < 0 || to < from || to >= slots.length) return;
  final completedIds = <String>{};
  for (var i = from; i <= to; i++) {
    completedIds.add(slots[i].turnId);
  }
  final summarySlot = _Slot(
    Message(
      role: Role.user,
      content: [TextBlock(summary)],
      isSynthetic: true,
    ),
    // Any turn id in the set filters the same way, so the first is as
    // good as any — the membership test is the per-id set, not one id.
    completedIds.first,
  );
  slots
    ..removeRange(from, to + 1)
    ..insert(from, summarySlot);
}
