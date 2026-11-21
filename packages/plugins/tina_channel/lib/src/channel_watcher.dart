import '../channel_store_api.dart';

/// Hard cap on a turn's channel context, in UTF-8 bytes.
const int channelDeliveryByteCap = 2048;

// Leave room for the headers and give new deliveries and recent context
// independent budgets so a burst cannot crowd out the entire history.
const _messageBudget = (channelDeliveryByteCap - 256) ~/ 2;
const _pageSize = 200;

/// Reads and acknowledges channel deliveries for one recipient session.
/// The durable checkpoint holds the scan position, a pending batch and a
/// bounded tail of previously delivered context.
final class ChannelWatcher {
  ChannelWatcher._(this._store, this._sessionId, this.agent, this._human);

  static ChannelWatcher start({
    required ChannelStoreApi store,
    required String sessionId,
    required String Function() selectAgent,
    required String human,
    String? agentName,
  }) {
    var state = store.deliveryState(sessionId);
    if (state == null) {
      final initial = ChannelDeliveryState(
        agent: agentName ?? selectAgent(),
        revision: 0,
        cursors: {
          for (final channel in store.listChannels())
            channel.name: channel.lastMessageId,
        },
      );
      state =
          store.saveDeliveryState(sessionId, initial, expectedRevision: null)
              ? initial
              : store.deliveryState(sessionId)!;
    }
    return ChannelWatcher._(store, sessionId, agentName ?? state.agent, human);
  }

  final ChannelStoreApi _store;
  final String _sessionId;
  final String agent;
  final String _human;
  bool _closed = false;
  int? _offeredRevision;

  bool routesTo(String name) =>
      name.toLowerCase() == agent.toLowerCase() ||
      name.toLowerCase() == _human.toLowerCase();

  /// Offers the pending batch until a completed turn acknowledges it.
  /// Recent delivered messages continue to accompany subsequent turns.
  String? deliverPending() {
    _offeredRevision = null;
    if (_closed) return null;
    while (true) {
      final current = _store.deliveryState(_sessionId)!;
      if (current.pending.isNotEmpty) return _offer(current);
      final next = _scan(current);
      if (next == null) return _offer(current);
      if (_store.saveDeliveryState(_sessionId, next,
          expectedRevision: current.revision)) {
        return _offer(next);
      }
    }
  }

  ChannelDeliveryState? _scan(ChannelDeliveryState current) {
    final candidates = [
      for (final channel in _store.listChannels())
        ..._store.read(channel.name,
            sinceId: current.cursors[channel.name] ?? 0,
            limit: _pageSize,
            fromOldest: true),
    ]..sort((a, b) => a.id.compareTo(b.id));
    if (candidates.isEmpty) return null;

    final cursors = Map.of(current.cursors);
    final pending = <String>[];
    var used = 0;
    for (final message in candidates.take(_pageSize)) {
      if (_routes(message.channel, message)) {
        final rendered = _render(message.channel, message);
        final line = _truncateBytes(rendered, _messageBudget - 1);
        final cost = line.utf8Length + 1;
        if (used + cost > _messageBudget) break;
        pending.add(line);
        used += cost;
      }
      cursors[message.channel] = message.id;
    }
    return ChannelDeliveryState(
      agent: agent,
      revision: current.revision + 1,
      cursors: cursors,
      pending: pending,
      recent: current.recent,
    );
  }

  String? _offer(ChannelDeliveryState state) {
    if (state.pending.isNotEmpty) _offeredRevision = state.revision;
    if (state.pending.isEmpty && state.recent.isEmpty) return null;
    return [
      '<group-channel-delivery>',
      'Channel posts are conversation context.',
      if (state.recent.isNotEmpty) ...[
        'Recent channel messages:',
        ...state.recent,
      ],
      if (state.pending.isNotEmpty) ...[
        'New channel messages addressed to you:',
        ...state.pending,
      ],
      '</group-channel-delivery>',
    ].join('\n');
  }

  /// Marks only the offered batch complete. A stale acknowledgement
  /// cannot consume a newer batch selected by another attachment.
  void acknowledge() {
    final revision = _offeredRevision;
    _offeredRevision = null;
    if (_closed || revision == null) return;
    final current = _store.deliveryState(_sessionId)!;
    if (current.revision != revision) return;

    final recent = [...current.recent, ...current.pending];
    var used = recent.fold(0, (size, message) => size + message.utf8Length + 1);
    var omit = 0;
    while (used > _messageBudget) {
      used -= recent[omit++].utf8Length + 1;
    }
    _store.saveDeliveryState(
      _sessionId,
      ChannelDeliveryState(
        agent: agent,
        revision: revision + 1,
        cursors: current.cursors,
        recent: recent.skip(omit),
      ),
      expectedRevision: revision,
    );
  }

  /// Clear conversation context while keeping any unacknowledged delivery.
  void clearRecent() {
    while (!_closed) {
      final current = _store.deliveryState(_sessionId)!;
      if (current.recent.isEmpty) return;
      if (_store.saveDeliveryState(
        _sessionId,
        ChannelDeliveryState(
          agent: agent,
          revision: current.revision + 1,
          cursors: current.cursors,
          pending: current.pending,
        ),
        expectedRevision: current.revision,
      )) {
        return;
      }
    }
  }

  bool _routes(String channel, ChannelMessage message) {
    if (message.sender.toLowerCase() == agent.toLowerCase()) return false;
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
          parent.sender.toLowerCase() == agent.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  String _render(String channel, ChannelMessage message) {
    final mention = message.mentions.isEmpty
        ? ''
        : ' @${message.mentions.join(',@')}';
    final reply = message.replyTo == null
        ? ''
        : ' (reply to #${message.replyTo})';
    final time = message.createdAt.toUtc().toIso8601String();
    return ('$channel ${message.sender}$mention$reply [$time]: ${message.text}')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  void close() => _closed = true;
}

String _truncateBytes(String text, int budget) {
  if (text.utf8Length <= budget) return text;
  final out = StringBuffer();
  var size = '…'.utf8Length;
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
