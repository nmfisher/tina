/// Pure presentation logic for the channel pane: the unread tracker
/// and the line renderer. No console, no io — deterministic and
/// testable with nothing but value types, which is how the smoke test
/// drives them.
library;

import 'package:tina_channel/tina_channel.dart';

/// Tracks per-channel unread counts for one reader. The store is
/// shared; "unread" is a per-reader notion, so the cursor lives here,
/// not in the store. Seed once (the pane opening baseline), refresh on
/// every poll, mark read when the channel is viewed.
final class ChannelUnread {
  final _lastSeen = <String, int>{};

  /// Sets the baseline: everything before the pane existed is read.
  void seed(Iterable<ChannelSummary> channels) {
    for (final channel in channels) {
      _lastSeen[channel.name] = channel.lastMessageId;
    }
  }

  /// Recomputes unread counts from a fresh channel listing.
  Map<String, int> refresh(Iterable<ChannelSummary> channels) {
    final unread = <String, int>{};
    for (final channel in channels) {
      final seen = _lastSeen[channel.name];
      if (seen == null) {
        // A channel first seen after seeding starts fully read unless
        // it has activity; otherwise every pre-existing channel would
        // flash unread on first poll.
        if (channel.lastMessageId > 0) {
          _lastSeen[channel.name] = channel.lastMessageId;
        }
        continue;
      }
      final delta = channel.lastMessageId - seen;
      if (delta > 0) unread[channel.name] = delta;
    }
    return unread;
  }

  /// The reader viewed the channel through [lastId]; the badge clears.
  void markRead(String channel, int lastId) {
    final previous = _lastSeen[channel] ?? 0;
    if (lastId > previous) _lastSeen[channel] = lastId;
  }

  /// The stored cursor, for tests and debugging.
  int cursor(String channel) => _lastSeen[channel] ?? 0;
}

/// Renders the pane body: the channel list (selected marker, unread
/// badge, counts), then the selected channel's recent messages with
/// sender labels and status markers, then a presence footer. Pure:
/// same inputs, same lines.
List<String> renderChannelPane({
  required List<ChannelSummary> channels,
  required Map<String, int> unread,
  required String selected,
  required List<ChannelMessage> messages,
  required List<ChannelMember> members,
  required int width,
  required int height,
}) {
  if (width < 8 || height < 3) return const [];
  String clip(String line) => line.length <= width ? line : line.substring(0, width - 1) + '…';

  final body = <String>[];
  for (final channel in channels) {
    final marker = channel.name == selected ? '❯' : ' ';
    final badge = unread[channel.name] ?? 0;
    body.add(clip('$marker ${channel.name}'
        '${badge > 0 ? ' ●$badge' : ''}'
        '  ${channel.messages}msg ${channel.members}mbr'));
  }
  if (body.isEmpty) body.add('no channels');
  body.add('');

  final room = height - body.length - 2; // header + footer
  final window = messages.length <= room || room < 1
      ? messages
      : messages.sublist(messages.length - room);
  if (window.isEmpty && room >= 1) body.add('(no messages)');
  for (final message in window) {
    body.add(clip(formatChannelLine(message)));
  }

  body.add(members.isEmpty
      ? 'nobody present'
      : 'present: ${members.map((m) => '${m.name} ${m.status}').join(', ')}');

  return [
    clip('Channels · ↑↓ select · PgUp/PgDn scroll · Esc close'),
    ...body,
  ];
}
