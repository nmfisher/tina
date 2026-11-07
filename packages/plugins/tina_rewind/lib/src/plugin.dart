/// Rewind: take the conversation back to an earlier point, without
/// touching the log's history. The command, the point enumeration and the
/// rewind operation live here; the cut derivation directive and the
/// active-log derivation are core language (`tina_core`) and the loop's
/// `cutFrom` is `tina_engine_2` — this plugin is the user-facing shell
/// over them, split out of `tina_session_controls` so rewind can be
/// enabled or disabled on its own.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

import 'rewind.dart';

/// Rewind data for the picker: the live log's points and its head.
abstract interface class RewindObservation {
  /// Rewind points of the live log, oldest first — the picker's data.
  /// Empty when the conversation has no rewindable history yet.
  List<RewindPoint> get rewindPoints;

  /// The seq of the last live entry, or -1 — the conversation's current
  /// position. A rewind request carries the head it was planned against.
  int get rewindHead;
}

/// The `/rewind` plugin.
final class RewindPlugin extends AgentPlugin {
  RewindPlugin({required this.terminal});

  final Terminal terminal;
  AgentLoop? _loop;
  bool _closed = false;

  late final RewindObservation observation = _RewindObservation(this);

  @override
  String get id => 'tina/rewind';

  @override
  void mountOn(AgentLoop loop) => _loop = loop;

  @override
  List<Command> get commands => [
    Command(
      name: 'rewind',
      description:
          'rewind the conversation to an earlier point '
          '(/rewind n = back n of your messages)',
      handler: (argument) {
        if (_closed) return;
        final loop = _loop;
        if (loop == null) return;
        final arg = argument.trim();
        if (arg.isEmpty) {
          _printRewindPoints(loop);
          return;
        }
        final back = int.tryParse(arg);
        if (back == null || back < 1) {
          terminal.writeln(
            'usage: /rewind [n] — n is how many of your messages to take back',
          );
          return;
        }
        final points = enumerateRewindPoints(
          loop.log,
        ).where((point) => point.kind == 'user').toList();
        if (points.isEmpty) {
          terminal.writeln('Nothing to rewind to yet.');
          return;
        }
        if (back > points.length) {
          terminal.writeln(
            'Only ${points.length} of your messages exist to rewind past.',
          );
          return;
        }
        try {
          rewindTo(
            toSeq: points[points.length - back].toSeq,
            expectedHead: rewindHeadOf(loop.log),
          );
        } on StateError catch (error) {
          terminal.writeln('Could not rewind: ${error.message}');
        }
      },
    ),
  ];

  /// Rewind the conversation to [toSeq] (exclusive bound), refusing when
  /// the conversation moved since the picker read [expectedHead] — the
  /// same staleness contract the model picker applies. Throws on a busy
  /// loop, an out-of-range bound or a closed session; callers report.
  void rewindTo({required int toSeq, required int expectedHead}) {
    if (_closed) throw StateError('Rewind is closed');
    final loop = _loop;
    if (loop == null) throw StateError('Rewind is closed');
    final head = rewindHeadOf(loop.log);
    if (head != expectedHead) {
      throw StateError('Conversation moved; open the picker again.');
    }
    try {
      // The generic engine API: append a cut derivation directive. All
      // rewind naming — the command, the notice, this plugin's id — stays
      // here; the loop knows directives only.
      loop.cutFrom(toSeq);
    } on RangeError catch (e) {
      throw StateError('Rewind point is no longer valid: ${e.message}');
    }
    terminal.writeln(_rewindNotice(toSeq));
  }

  /// The one-line scope notice every rewind prints: the conversation
  /// rewinds, the filesystem does not.
  static String _rewindNotice(int toSeq) =>
      'Rewound to entry $toSeq. Filesystem effects of earlier tool calls '
      'are not undone.';

  void _printRewindPoints(AgentLoop loop) {
    final points = enumerateRewindPoints(loop.log);
    if (points.isEmpty) {
      terminal.writeln('Nothing to rewind to yet.');
      return;
    }
    terminal.writeln(
      'Rewind points (current position: after entry ${rewindHeadOf(loop.log)}):',
    );
    for (var i = 0; i < points.length; i++) {
      final stamp = _clock(points[i].at);
      terminal.writeln(
        '  ${i + 1}  $stamp  ${points[i].label}'
        '${points[i].kind == 'compaction' ? '  [compaction]' : ''}',
      );
    }
    terminal.writeln(
      '/rewind <n> takes back your last <n> messages; a console front end '
      'opens a picker for /rewind alone.',
    );
  }

  /// Local HH:mm of a log timestamp, blank when unreadable.
  static String _clock(String at) {
    final time = DateTime.tryParse(at)?.toLocal();
    if (time == null) return '';
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  void closeSession() {
    _closed = true;
    _loop = null;
  }
}

final class _RewindObservation implements RewindObservation {
  _RewindObservation(this._plugin);
  final RewindPlugin _plugin;
  @override
  List<RewindPoint> get rewindPoints =>
      enumerateRewindPoints(_plugin._loop?.log ?? const []);
  @override
  int get rewindHead => rewindHeadOf(_plugin._loop?.log ?? const []);
}
