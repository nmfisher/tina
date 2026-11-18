import '../channel_store_api.dart';

/// Hard cap on one delivery's rendered size, in UTF-8 bytes. Overflow
/// drops oldest-first with a `… and N more` line, so a burst cannot
/// flood a turn boundary; what exceeds the cap stays pull-only
/// (`channel_read`).
const int channelDeliveryByteCap = 2048;

/// Renders turn-boundary deliveries of new channel messages: the
/// watcher half of passive delivery. One instance serves one agent in
/// one session — [ChannelPlugin] owns its lifecycle and calls
/// [deliverPending] at its turn boundary (the prompt-section seam, so
/// the engine needs no new event surface and engine packages stay off
/// direct I/O: everything here goes through the store contract).
///
/// Routing is mention-only by default. An arriving message is
/// delivered when it mentions this agent's shortcode, replies to one
/// of its messages, or comes from the session's human — everything
/// else stays pull-only. The agent's own messages are never delivered
/// back to it. Every message EXAMINED advances the per-channel cursor
/// (delivered or not), so nothing is re-scanned and nothing is ever
/// delivered twice; `channel_read` keeps its independent explicit
/// catch-up role.
///
/// The cursor starts at the newest message per channel when the
/// watcher is created ([ChannelWatcher.start]): history that predates
/// the session is pull-only by design.
final class ChannelWatcher {
  ChannelWatcher._(this._store, this._agent, this._human);

  /// Starts watching [store] as [agent] (the session's settled
  /// shortcode). [human] is the name the session's human posts under.
  /// Existing channels' cursors are pinned to their newest message —
  /// history is explicit catch-up, not delivery.
  static ChannelWatcher start({
    required ChannelStoreApi store,
    required String agent,
    required String human,
  }) {
    final watcher = ChannelWatcher._(store, agent, human);
    for (final channel in store.listChannels()) {
      watcher._cursors[channel.name] = channel.lastMessageId;
    }
    return watcher;
  }

  final ChannelStoreApi _store;
  final String _agent;
  final String _human;
  final _cursors = <String, int>{};
  bool _closed = false;

  /// Whether a mention of [name] (without the `@`) addresses this
  /// watcher's agent or its session's human. Public for tests of the
  /// routing rule itself.
  bool routesTo(String name) =>
      name.toLowerCase() == _agent.toLowerCase() ||
      name.toLowerCase() == _human.toLowerCase();

  /// Renders and clears everything deliverable right now: one prompt
  /// section listing the routed messages, or null when nothing new is
  /// routed to this agent. A non-null result marks the cursors — the
  /// same messages are never delivered twice. Capped at
  /// [channelDeliveryByteCap]; overflow drops the OLDEST entries and
  /// reports them in a leading `… and N more` line.
  String? deliverPending() {
    if (_closed) return null;
    final delivered = <_Rendered>[];
    for (final channel in _store.listChannels()) {
      final cursor = _cursors[channel.name] ?? 0;
      final batch = _store.read(channel.name, sinceId: cursor, limit: 200);
      var examined = cursor;
      for (final message in batch) {
        if (message.id > examined) examined = message.id;
        if (!_routes(channel.name, message)) continue;
        delivered.add(_render(channel.name, message));
      }
      _cursors[channel.name] = examined;
    }
    if (delivered.isEmpty) return null;
    // A single oversized message is truncated in place rather than
    // blowing the budget: mentions must still deliver, bounded.
    for (var i = 0; i < delivered.length; i++) {
      if (delivered[i].text.utf8Length > channelDeliveryByteCap) {
        delivered[i] = _Rendered(_truncateBytes(
            delivered[i].text, channelDeliveryByteCap ~/ 2));
      }
    }
    var kept = delivered;
    var elided = 0;
    while (true) {
      final section = _section(kept, elided);
      // A single entry is at most half the cap (truncated above), so
      // the loop always settles with at least one delivered message;
      // should that invariant ever break, the elision-only section
      // still signals that traffic arrived instead of dropping the
      // turn silently.
      if (section.utf8Length <= channelDeliveryByteCap || kept.isEmpty) {
        return section;
      }
      // Over budget: drop the oldest entry and account for it in a
      // leading elision line (budgeted like any other content).
      kept = kept.sublist(1);
      elided++;
    }
  }

  String _section(List<_Rendered> kept, int elided) {
    final elision = elided == 0
        ? ''
        : '… and $elided more older message'
              '${elided == 1 ? '' : 's'} not shown\n';
    return '<group-channel-delivery>\n'
        'New channel messages addressed to you (delivery is automatic; '
        'do not poll channel_read for these):\n'
        '$elision${kept.map((m) => m.text).join('\n')}\n'
        '</group-channel-delivery>';
  }

  bool _routes(String channel, ChannelMessage message) {
    if (message.sender.toLowerCase() == _agent.toLowerCase()) return false;
    // The human's messages always reach this agent — the owner is
    // never filtered.
    if (message.sender.toLowerCase() == _human.toLowerCase()) return true;
    // Writers parse @names into the stored mentions; a raw store write
    // that skipped them still routes by its text.
    final mentions = message.mentions.isNotEmpty
        ? message.mentions
        : parseMentions(message.text);
    for (final mention in mentions) {
      if (routesTo(mention)) return true;
    }
    final replyTo = message.replyTo;
    if (replyTo != null) {
      final parent = _store.message(channel, replyTo);
      if (parent != null &&
          parent.sender.toLowerCase() == _agent.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  _Rendered _render(String channel, ChannelMessage message) {
    final mention = message.mentions.isEmpty
        ? ''
        : ' @${message.mentions.join(',@')}';
    final reply = message.replyTo == null
        ? ''
        : ' (reply to #${message.replyTo})';
    final time = message.createdAt.toUtc().toIso8601String();
    return _Rendered(
      '$channel ${message.sender}$mention$reply [$time]: '
      '${message.text}',
    );
  }

  /// Releases the watcher. After this, [deliverPending] is a no-op;
  /// the store itself belongs to the plugin that owns this watcher.
  void close() {
    _closed = true;
    _cursors.clear();
  }
}

final class _Rendered {
  const _Rendered(this.text);
  final String text;
}

String _truncateBytes(String text, int budget) {
  final out = StringBuffer();
  var size = 1; // room for the ellipsis
  for (final rune in text.runes) {
    final w = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
            ? 2
            : rune <= 0xffff
                ? 3
                : 4;
    if (size + w > budget) break;
    out.writeCharCode(rune);
    size += w;
  }
  return '${out}…';
}

extension on String {
  int get utf8Length => runes.fold(0, (n, r) => n + _utf8Size(r));

  static int _utf8Size(int rune) {
    if (rune <= 0x7f) return 1;
    if (rune <= 0x7ff) return 2;
    if (rune <= 0xffff) return 3;
    return 4;
  }
}
