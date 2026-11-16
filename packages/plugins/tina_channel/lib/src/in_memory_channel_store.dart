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
          messages: _messages.where((m) => m.channel == name).length,
          members: _members[name]?.length ?? 0,
          lastMessageId: lastMessageId(name),
          lastMessageAt: _last(_messages, name)?.createdAt,
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
    final matched = _messages
        .where((m) =>
            m.channel == normalized &&
            (sinceId == null || m.id > sinceId) &&
            (sinceTime == null || m.createdAt.isAfter(sinceTime)))
        .toList();
    if (matched.length <= limit) return matched;
    return matched.sublist(matched.length - limit);
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
      post(normalized,
          sender: member,
          text: summary == null || summary.isEmpty
              ? '$member is $status'
              : '$member is $status — $summary',
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
