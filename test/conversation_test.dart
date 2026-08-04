import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina/conversation.dart';
import 'package:test/test.dart';

import 'helpers/fake_agent_sink.dart';
import 'helpers/fake_host_interface.dart';
import 'helpers/fake_provider.dart';

/// Builds a [Conversation] with faked dependencies. [Conversation] is a thin
/// data holder, so this wires just enough to exercise its own contract (history
/// seeding, the running flag, the message queue) without driving a turn. The
/// host is a [FakeHostInterface] only because [Conversation] requires a
/// [HostInterface]; no turn runs, so nothing is written to it.
Conversation _conversation({List<Message> initialHistory = const []}) {
  final provider = FakeProvider(const []);
  final host = FakeHostInterface();
  return Conversation(
    id: 'c1',
    label: 'test',
    agent: Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: FakeAgentSink(),
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      system: 'sys',
    ),
    provider: provider,
    host: host,
    policy: PermissionPolicy(),
    initialHistory: initialHistory,
  );
}

void main() {
  group('Conversation', () {
    test('initialHistory is copied and not aliased with the source list', () {
      final seed = <Message>[
        const Message(role: Role.user, content: [TextBlock('hi')]),
      ];
      final c = _conversation(initialHistory: seed);

      expect(c.history, hasLength(1));
      expect((c.history.single.content.single as TextBlock).text, 'hi');

      // Mutating the source list after construction must not leak in — the
      // conversation owns its own copy.
      seed.add(const Message(role: Role.assistant, content: [TextBlock('late')]));
      expect(c.history, hasLength(1));
    });

    test('isRunning tracks the cancelCompleter', () {
      final c = _conversation();

      expect(c.isRunning, isFalse); // no cancelCompleter set

      c.cancelCompleter = Completer<void>();
      expect(c.isRunning, isTrue); // set and uncompleted

      c.cancelCompleter!.complete();
      expect(c.isRunning, isFalse); // completed → idle
    });

    test('messageQueue is a working queue on the instance', () {
      final c = _conversation();

      expect(c.messageQueue.isEmpty, isTrue);
      c.messageQueue.enqueue('  hello  '); // MessageQueue trims
      expect(c.messageQueue.length, 1);
      expect(c.messageQueue.dequeue(), 'hello');
      expect(c.messageQueue.dequeue(), isNull);
    });
  });
}
