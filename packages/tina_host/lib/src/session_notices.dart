part of 'host.dart';

/// Informational output from the session owner. These records are transient,
/// independently sequenced, and ordered after a committed history position.
final class SessionNotice {
  const SessionNotice._(this.seq, this.afterHistorySeq, this.text,
      {this.truncated = false});
  final int seq, afterHistorySeq;
  final String text;
  final bool truncated;
}

final class SessionNoticePage {
  SessionNoticePage._(Iterable<SessionNotice> entries, this.nextAfterSeq,
      this.hasMore, this.omittedThroughSeq, this.omittedAfterHistorySeq)
      : entries = List.unmodifiable(entries);
  final List<SessionNotice> entries;
  final int nextAfterSeq;
  final bool hasMore;

  /// Missing records expired from memory. The history position lets a renderer
  /// place the omission marker correctly relative to a later conversation clear.
  final int? omittedThroughSeq, omittedAfterHistorySeq;
}

/// Owner-side notice writer. The host takes ownership at startup; clients read
/// through SessionConnection and cannot publish session-wide output.
final class SessionNotices {
  SessionNotices(
      {this.maxEntries = 256,
      this.maxCharacters = 262144,
      this.maxNoticeCharacters = 16384}) {
    if (maxEntries < 1 || maxCharacters < 1 || maxNoticeCharacters < 1)
      throw ArgumentError('Notice retention limits must be positive');
  }
  final int maxEntries, maxCharacters, maxNoticeCharacters;
  final _entries = <SessionNotice>[];
  int _nextSeq = 0, _characters = 0, _visibleThrough = -1;
  int _expiredThrough = -1, _expiredAfterHistorySeq = -1;
  Host? _host;
  bool _closed = false;

  /// Bounded diagnostic output for the owning application. Frontends use the
  /// connection's watermarked pages instead.
  List<SessionNotice> get retained => List.unmodifiable(_entries);

  void write(String text) {
    if (_closed) return;
    final limit = min(maxCharacters, maxNoticeCharacters);
    final value = text.length > limit ? text.substring(0, limit) : text;
    _entries.add(SessionNotice._(
        _nextSeq++, (_host?.session.loop.seq ?? 0) - 1, value,
        truncated: value.length != text.length));
    _characters += value.length;
    _through(_host?.session.loop.publishedSeq ?? -1);
    while (_entries.length > maxEntries || _characters > maxCharacters) {
      final removed = _entries.removeAt(0);
      _characters -= removed.text.length;
      _expiredThrough = removed.seq;
      _expiredAfterHistorySeq = removed.afterHistorySeq;
    }
    _host?._changed();
  }

  void _mount(Host host) {
    if (_host != null || _closed)
      throw StateError('Notice writer already owned');
    _host = host;
    // Startup output follows restored history when resuming a session.
    final position = host.session.loop.seq - 1;
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      _entries[i] = SessionNotice._(entry.seq, position, entry.text,
          truncated: entry.truncated);
    }
    _expiredAfterHistorySeq = position;
  }

  int _through(int historySeq) {
    for (final entry in _entries) {
      if (entry.afterHistorySeq > historySeq) break;
      _visibleThrough = max(_visibleThrough, entry.seq);
    }
    return _visibleThrough;
  }

  SessionNoticePage _page(SessionSnapshot snapshot, int afterSeq, int limit) {
    final through = snapshot.throughNoticeSeq;
    final omitted = min(_expiredThrough, through);
    final start = max(afterSeq, omitted);
    final entries = _entries
        .where((entry) => entry.seq > start && entry.seq <= through)
        .take(limit)
        .toList();
    final next = entries.isEmpty ? start : entries.last.seq;
    return SessionNoticePage._(
        entries,
        next,
        next < through,
        omitted > afterSeq ? omitted : null,
        omitted > afterSeq
            ? min(_expiredAfterHistorySeq, snapshot.throughSeq)
            : null);
  }

  void _close() {
    _closed = true;
  }
}
