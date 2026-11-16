import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel_tui/tina_channel_tui.dart';

/// The pane is pure presentation over the store interface: this smoke
/// test drives an in-memory store (the wasm seam twin), so nothing
/// here links sqlite.
void main() {
  group('ChannelUnread', () {
    test('seeding baselines; refresh counts new rows only', () {
      final store = InMemoryChannelStore();
      store.post('#lobby', sender: 'a', text: 'before the pane opened');
      final unread = ChannelUnread()..seed(store.listChannels());
      expect(unread.refresh(store.listChannels()), isEmpty);

      store.post('#lobby', sender: 'a', text: 'new');
      store.post('#lobby', sender: 'a', text: 'newer');
      expect(unread.refresh(store.listChannels()), {'#lobby': 2});

      unread.markRead('#lobby', store.lastMessageId('#lobby'));
      expect(unread.refresh(store.listChannels()), isEmpty);
    });

    test('a channel first seen after seeding starts read', () {
      final store = InMemoryChannelStore();
      final unread = ChannelUnread()..seed(store.listChannels());
      store.post('#late', sender: 'a', text: 'appears later');
      expect(unread.refresh(store.listChannels()), isEmpty);
      store.post('#late', sender: 'a', text: 'then grows');
      expect(unread.refresh(store.listChannels()), {'#late': 1});
    });
  });

  group('renderChannelPane', () {
    test('shows channels, unread badges, messages and presence', () {
      final store = InMemoryChannelStore();
      store.post('#lobby', sender: 'tina-main', text: 'starting the pane work');
      store.setMember('#lobby', 'subagent',
          status: 'working', summary: 'schema review');
      final messages = store.read('#lobby');

      final lines = renderChannelPane(
        channels: store.listChannels(),
        unread: const {'#lobby': 3},
        selected: '#lobby',
        messages: messages,
        members: store.members('#lobby'),
        width: 60,
        height: 12,
      );

      expect(lines.first, contains('Channels'));
      final lobbyLine =
          lines.firstWhere((l) => l.contains('#lobby'));
      expect(lobbyLine, contains('●3'));
      expect(lobbyLine, contains('❯'));
      expect(lines.join('\n'), contains('tina-main'));
      expect(lines.join('\n'), contains('* subagent'));
      expect(lines.join('\n'), contains('present: subagent working'));
    });

    test('clips long lines to the pane width', () {
      final store = InMemoryChannelStore();
      store.post('#lobby', sender: 'a', text: 'x' * 200);
      final lines = renderChannelPane(
        channels: store.listChannels(),
        unread: const {},
        selected: '#lobby',
        messages: store.read('#lobby'),
        members: const [],
        width: 20,
        height: 8,
      );
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(20));
      }
    });

    test('empty workspace renders a hint, not a crash', () {
      final lines = renderChannelPane(
        channels: const [],
        unread: const {},
        selected: '#lobby',
        messages: const [],
        members: const [],
        width: 40,
        height: 6,
      );
      expect(lines.join('\n'), contains('no channels'));
    });
  });
}
