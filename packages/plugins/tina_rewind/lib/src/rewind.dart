import 'package:tina_core/tina_core.dart';

/// One point `/rewind` may cut to, derived from the live log.
///
/// [toSeq] is the exclusive bound the [RewoundEntry] will carry: entries
/// with `seq < toSeq` stay live. For a user message that is the seq of the
/// turn that contains it — the message and everything after it never
/// happened. For a compaction boundary it is the [CompactedEntry]'s own
/// seq: the compaction is dropped and context re-derives from the raw
/// prefix.
final class RewindPoint {
  const RewindPoint({
    required this.toSeq,
    required this.at,
    required this.label,
    required this.kind,
  });

  /// Exclusive live bound: entries with `seq < toSeq` stay live.
  final int toSeq;

  /// Timestamp of the anchor entry, as the log recorded it.
  final String at;

  /// Display label: the first ~80 characters of the user's message, or of
  /// the compaction summary.
  final String label;

  /// Either `user` or `compaction`.
  final String kind;

  @override
  String toString() => 'RewindPoint($kind, to $toSeq, $label)';
}

/// The seq of the last live entry, or -1 when nothing is live — the
/// conversation's current position, as `/rewind` reports it.
int rewindHeadOf(List<SessionEntry> log) {
  final active = activeLog(log);
  return active.isEmpty ? -1 : active.last.seq;
}

/// Every rewind point in the live log, oldest first: each of the user's
/// own recorded inputs plus every compaction boundary. Points inside a
/// rewound-away tail are not offered — they already never happened.
List<RewindPoint> enumerateRewindPoints(List<SessionEntry> log) {
  final points = <RewindPoint>[];
  var turnStart = 0;
  for (final entry in activeLog(log)) {
    switch (entry) {
      case TurnStartedEntry():
        turnStart = entry.seq;
      case InputRecordedEntry(:final text, :final at):
        points.add(
          RewindPoint(
            toSeq: turnStart,
            at: at,
            label: _label(text),
            kind: 'user',
          ),
        );
      case CompactedEntry(:final at, :final summary):
        points.add(
          RewindPoint(
            toSeq: entry.seq,
            at: at,
            label: _label(summary),
            kind: 'compaction',
          ),
        );
      default:
        break;
    }
  }
  return points;
}

String _label(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 80 ? flat : '${flat.substring(0, 79)}…';
}
