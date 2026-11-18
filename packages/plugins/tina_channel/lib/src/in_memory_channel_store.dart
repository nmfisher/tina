/// A pure-Dart [ChannelStoreApi] implementation: one store per process,
/// same semantics as the sqlite twin. It exists so anything that cannot
/// open a file (the wasm engine, deterministic tests) still gets a
/// conforming store, and so the seam is exercised on both sides.
library;

import '../channel_store_api.dart';

final class InMemoryChannelStore implements ChannelStoreApi {
  InMemoryChannelStore() {
    ensureChannel('#lobby');
  }

  static DateTime _now() => DateTime.now().toUtc();

  /// The channel's current view: every message past its compaction
  /// point, oldest first.
  List<ChannelMessage> _view(String channel) => _messages
      .where((m) => m.channel == channel && m.id > (_compaction[channel] ?? 0))
      .toList();

  @override
  int compactionPoint(String channel) =>
      _compaction[normalizeChannelName(channel)] ?? 0;

  @override
  ChannelCompaction compact(String channel,
      {required String actor,
      int keep = compactDefaultKeep,
      bool clear = false}) {
    if (keep < 0) throw const FormatException('keep must not be negative');
    final normalized = normalizeChannelName(channel);
    // _view already floors at the prior compaction point: a compacted
    // room never resurrects superseded rows.
    final prior = _compaction[normalized] ?? 0;
    final view = _view(normalized);
    final newest = view.isEmpty ? 0 : view.last.id;
    final retained = clear ? 0 : keep;
    final tail = view.length <= retained ? view : view.sublist(view.length - retained);
    final point = tail.isEmpty ? newest : tail.first.id - 1;
    final superseded = _messages
        .where((m) => m.channel == normalized && m.id > prior && m.id <= point)
        .toList();
    final digested = superseded.length;
    var digestId = 0;
    if (!clear) {
      final digest = post(normalized,
          sender: actor,
          text: 'Compacted $normalized: superseded $digested '
              'message${digested == 1 ? '' : 's'} '
              '(ids ${prior + 1}\u{2013}$point); '
              '${tail.length} recent message${tail.length == 1 ? '' : 's'} '
              'retained. Full history stays in the database.',
          type: ChannelMessageType.system);
      digestId = digest.id;
    }
    _compaction[normalized] = point;
    return ChannelCompaction(
      channel: normalized,
      point: point,
      digested: digested,
      digestId: digestId,
      superseded: superseded,
    );
  }

  static ChannelMessage? _last(List<ChannelMessage> rows, String channel) {
    ChannelMessage? found;
    for (final m in rows) {
      if (m.channel == channel) found = m;
    }
    return found;
  }

  final _channels = <String, DateTime>{};
  final _messages = <ChannelMessage>[];
  final _members = <String, Map<String, ChannelMember>>{};
  final _compaction = <String, int>{};
  var _nextId = 1;

  @override
  String get file => ':memory:';

  @override
  void ensureChannel(String name) {
    _channels.putIfAbsent(normalizeChannelName(name), _now);
  }

  @override
  List<ChannelSummary> listChannels() {
    final names = _channels.keys.toList()..sort();
    return [
      for (final name in names)
        ChannelSummary(
          name: name,
          messages: _view(name).length,
          members: _members[name]?.length ?? 0,
          lastMessageId: _view(name).isEmpty
              ? 0
              : _view(name).last.id,
          lastMessageAt: _last(_view(name), name)?.createdAt,
        )
    ];
  }

  @override
  ChannelMessage post(String channel,
      {required String sender,
      required String text,
      ChannelMessageType type = ChannelMessageType.message,
      List<String>? mentions,
      int? replyTo}) {
    if (sender.trim().isEmpty) throw const FormatException('sender is empty');
    final normalized = normalizeChannelName(channel);
    _channels.putIfAbsent(normalized, _now);
    final message = ChannelMessage(
      id: _nextId++,
      channel: normalized,
      sender: sender,
      text: text,
      type: type,
      mentions: mentions == null ? const [] : List.of(mentions),
      replyTo: replyTo,
      createdAt: DateTime.now().toUtc(),
    );
    _messages.add(message);
    return message;
  }

  @override
  List<ChannelMessage> read(String channel,
      {int? sinceId, DateTime? sinceTime, int limit = 50}) {
    if (limit < 1) throw const FormatException('limit must be at least 1');
    final normalized = normalizeChannelName(channel);
    final point = _compaction[normalized] ?? 0;
    final since = sinceId == null
        ? point
        : sinceId > point
            ? sinceId
            : point;
    final matched = _messages
        .where((m) =>
            m.channel == normalized &&
            (since == 0 || m.id > since) &&
            (sinceTime == null || m.createdAt.isAfter(sinceTime)))
        .toList();
    if (matched.length <= limit) return matched;
    return matched.sublist(matched.length - limit);
  }

  @override
  ChannelMessage? message(String channel, int id) {
    final normalized = normalizeChannelName(channel);
    for (final m in _messages) {
      if (m.channel == normalized && m.id == id) return m;
    }
    return null;
  }

  @override
  void setMember(String channel, String member,
      {required String status,
      String? role,
      String? summary,
      bool announce = true}) {
    if (member.trim().isEmpty) throw const FormatException('member is empty');
    final normalized = normalizeChannelName(channel);
    _channels.putIfAbsent(normalized, _now);
    _members
        .putIfAbsent(normalized, () => {})
        [member] = ChannelMember(
      channel: normalized,
      name: member,
      role: role ?? 'agent',
      status: status,
      summary: summary,
      lastSeen: DateTime.now().toUtc(),
    );
    if (announce) {
      // The sender column carries the name; the text stays name-less so
      // rendered lines read `* nick working — …`.
      post(normalized,
          sender: member,
          text: summary == null || summary.isEmpty
              ? status
              : '$status — $summary',
          type: ChannelMessageType.status);
    }
  }

  @override
  List<ChannelMember> members(String channel) {
    final normalized = normalizeChannelName(channel);
    final members = _members[normalized]?.values.toList() ?? const [];
    return [...members]..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  int lastMessageId(String channel) {
    final normalized = normalizeChannelName(channel);
    var last = 0;
    for (final m in _messages) {
      if (m.channel == normalized && m.id > last) last = m.id;
    }
    return last;
  }

  @override
  void close() {}
}
