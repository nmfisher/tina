import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';

/// Phase 3 — the watcher: mention routing, per-agent cursors, the
/// delivery cap, human always-delivered, and lifecycle. The watcher is
/// driven directly (per the issue's terms); the turn-boundary wiring
/// is the plugin's one-line prompt-section call, covered by the
/// plugin test.
void main() {
  late InMemoryChannelStore store;
  late ChannelWatcher watcher;

  setUp(() {
    store = InMemoryChannelStore();
    // Start the watcher AFTER some history exists: pre-session history
    // is pull-only, so the cursor must pin to the newest row.
    store.post('#lobby', sender: 'prior-agent', text: 'old business');
    watcher = ChannelWatcher.start(
        store: store,
        sessionId: 'recipient',
        selectAgent: () => 'calm-heron',
        human: 'user');
  });

  group('routing', () {
    test('a mention of the shortcode delivers; unmentioned does not', () {
      store.post('#lobby',
          sender: 'other-agent', text: 'unrelated chatter', mentions: []);
      expect(watcher.deliverPending(), isNull,
          reason: 'unmentioned messages stay pull-only');

      store.post('#lobby', sender: 'other-agent',
          text: '@calm-heron please check the store');
      final delivered = watcher.deliverPending();
      expect(delivered, contains('please check the store'));
      expect(delivered, contains('@calm-heron'));
    });

    test('a reply to the agent message delivers', () {
      final mine = store.post('#lobby',
          sender: 'calm-heron', text: 'I own the store layer');
      store.post('#lobby',
          sender: 'other-agent',
          text: 'confirmed',
          replyTo: mine.id,
          mentions: []);
      final delivered = watcher.deliverPending();
      expect(delivered, contains('confirmed'));
      expect(delivered, contains('(reply to #${mine.id})'));
    });

    test('a reply to someone else stays pull-only', () {
      final theirs = store.post('#lobby',
          sender: 'other-agent', text: 'not my thread');
      store.post('#lobby',
          sender: 'third-agent',
          text: 'likewise',
          replyTo: theirs.id,
          mentions: []);
      expect(watcher.deliverPending(), isNull);
    });

    test('the human is never filtered', () {
      store.post('#lobby', sender: 'user', text: 'status?', mentions: []);
      final delivered = watcher.deliverPending();
      expect(delivered, isNotNull,
          reason: 'the owner always reaches every agent');
      expect(delivered, contains('status?'));
    });

    test('the agent never receives its own messages', () {
      store.post('#lobby',
          sender: 'calm-heron', text: '@calm-heron note to self');
      expect(watcher.deliverPending(), isNull);
    });

    test('mentions route case-insensitively and across channels', () {
      store.ensureChannel('#side');
      store.post('#side',
          sender: 'other-agent', text: 'heads up @Calm-Heron');
      expect(watcher.deliverPending(), contains('#side'));
    });

    test('status rows deliver only when they mention', () {
      store.post('#lobby',
          sender: 'other-agent',
          text: 'idle',
          type: ChannelMessageType.status,
          mentions: []);
      expect(watcher.deliverPending(), isNull);
      store.post('#lobby',
          sender: 'other-agent',
          text: 'done — over to @calm-heron',
          type: ChannelMessageType.status);
      expect(watcher.deliverPending(), contains('over to @calm-heron'));
    });
  });

  group('cursors', () {
    test('a batch stays pending until acknowledged and then becomes context', () {
      store.post('#lobby',
          sender: 'other-agent', text: '@calm-heron once');
      final first = watcher.deliverPending();
      expect(first, contains('once'));
      expect(watcher.deliverPending(), first);
      watcher.acknowledge();
      final later = watcher.deliverPending();
      expect(later, contains('Recent channel messages:'));
      expect(later, contains('once'));
      expect(later, isNot(contains('New channel messages')));
    });

    test('unrouted messages also advance the cursor (no rescans)', () {
      store.post('#lobby', sender: 'other-agent', text: 'not for me');
      expect(watcher.deliverPending(), isNull);
      expect(watcher.deliverPending(), isNull,
          reason: 'already examined; never re-delivered later');
    });

    test('a stale acknowledgement cannot consume a newer pending batch', () {
      final other = ChannelWatcher.start(
        store: store,
        sessionId: 'recipient',
        selectAgent: () => throw StateError('already initialized'),
        human: 'user',
      );
      addTearDown(other.close);
      store.post('#lobby', sender: 'user', text: 'first batch');
      expect(other.deliverPending(), watcher.deliverPending());
      watcher.acknowledge();
      store.post('#lobby', sender: 'user', text: 'second batch');
      final second = watcher.deliverPending();
      expect(second, contains('second batch'));
      other.acknowledge();
      expect(watcher.deliverPending(), second);
      expect(store.deliveryState('recipient')!.pending.single,
          contains('second batch'));
    });

    test('channel_read stays independent of the delivery cursor', () {
      store.post('#lobby', sender: 'other-agent', text: 'not for me');
      store.post('#lobby',
          sender: 'other-agent', text: '@calm-heron for me');
      watcher.deliverPending();
      final catchUp = store.read('#lobby');
      expect(catchUp.any((m) => m.text == 'not for me'), isTrue,
          reason: 'explicit reads still see everything');
    });

    test('pre-session history is pull-only', () {
      expect(watcher.deliverPending(), isNull,
          reason: 'the old-business row predates the watcher');
      expect(store.read('#lobby').last.text, 'old business');
    });
  });

  group('cap', () {
    test('overflow stays pending in the channel for the next batch', () {
      for (var i = 1; i <= 40; i++) {
        store.post('#lobby',
            sender: 'other-agent', text: '@calm-heron message [$i]');
      }
      final seen = <int>[];
      for (var batch = 0; batch < 40 && seen.length < 40; batch++) {
        final delivered = watcher.deliverPending()!;
        expect(utf8.encode(delivered).length, lessThanOrEqualTo(channelDeliveryByteCap));
        final pending = store.deliveryState('recipient')!.pending;
        for (final line in pending) {
          seen.add(int.parse(RegExp(r'message \[(\d+)\]').firstMatch(line)![1]!));
        }
        watcher.acknowledge();
      }
      expect(seen, List.generate(40, (i) => i + 1));
    });

    test('a single huge message cannot blow the turn', () {
      store.post('#lobby',
          sender: 'other-agent',
          text: '@calm-heron ${'x' * (channelDeliveryByteCap + 5000)}');
      final delivered = watcher.deliverPending();
      expect(delivered, isNotNull,
          reason: 'the mention still delivers');
      expect(utf8.encode(delivered!).length, lessThanOrEqualTo(channelDeliveryByteCap),
          reason: 'rendering stays bounded even for oversized input');
    });
  });

  group('lifecycle', () {
    test('a closed watcher delivers nothing and holds no state', () {
      store.post('#lobby',
          sender: 'other-agent', text: '@calm-heron late arrival');
      watcher.close();
      expect(watcher.deliverPending(), isNull);
      // Closing is idempotent and the store outlives the watcher: the
      // owning plugin closes it; nothing in the watcher keeps timers,
      // subscriptions or file handles of its own.
      watcher.close();
    });
  });
}
