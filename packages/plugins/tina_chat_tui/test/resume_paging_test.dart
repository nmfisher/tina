import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _History extends AgentPlugin {
  _History(this.entries);
  final List<SessionEntry> entries;
  @override
  String get id => 'test/history';
  @override
  SessionSeed openSession(PluginSession session) =>
      SessionSeed(log: entries, details: SessionDetails());
}

final class _Io implements Stdio {
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

List<SessionEntry> history(int turns) => [
      for (var i = 0; i < turns; i++) ...[
        InputRecordedEntry(seq: i * 2, turnId: 'turn-$i', text: 'question $i'),
        MessageAppendedEntry(
            seq: i * 2 + 1,
            turnId: 'turn-$i',
            message: Message(
              role: Role.assistant,
              content: [TextBlock('**answer $i**')],
          reasoning: i == turns - 1
              ? const [ReasoningBlock('latest reasoning')]
              : const [],
            )),
      ],
    ];

void main() {
  for (final turns in [50, 5000]) {
    test('resume paints a recent page, not all ${turns * 2} entries', () async {
      final runtime = ChatPlugin(model: 'fixture', showSessionId: false);
      final projected = <int>[];
      final host = Host.resume(
          HostConfig(
              workingDirectory: '.',
              plugins: [_History(history(turns)), runtime],
              providerFactory: (_) =>
                  ScriptedProvider([scriptedReply('live reply')]),
              snapshotFeatureFor: (plugin) => plugin is ChatPlugin
                  ? SnapshotFeature(
                      () => {
                            ...runtime.observation.events.snapshot,
                            'session_tokens': 12345,
                            'show_session_id': false,
                          },
                      listen: runtime.observation.events.listenChanges,
                      historyMetadata: (entry) {
                      projected.add(entry.seq);
                      return runtime.historyMetadata(entry);
                    })
                  : null),
          'saved');
      addTearDown(host.shutdown);
      final connection = host.connect();
      addTearDown(connection.close);
      final io = _Io();
      final screen =
          Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
      final editor = LineEditor(screen: screen);
      final context = ConsoleContext(screen: screen, editor: editor);
      final view = ChatView(ConnectionChatObservation(connection));
      addTearDown(() {
        view.detachConsole();
        editor.close(reportLatency: false);
        screen.dispose();
      });
      final watch = Stopwatch()..start();
      view.attachConsole(context);
      watch.stop();
      expect(projected.length, lessThanOrEqualTo(128));
      expect(projected.first, greaterThan(0));
      expect(view.blocks.length, lessThanOrEqualTo(128));
      expect(screen.chat.snapshotLines().join('\n'),
          contains('answer ${turns - 1}'));
      expect(io.output.toString(), isNot(contains('question 0')));
      expect(io.output.toString(), contains('12,345'));
      print('${turns * 2} entries: ${projected.length} projected, '
          '${watch.elapsedMicroseconds / 1000} ms to attach');

      final before = projected.length;
      final firstSeq = projected.first;
      view.blocks.singleWhere((b) => b.kind == ChatBlockKind.reasoning)
          .folded = false;
      screen.chat.scrollBy(-1);
      expect(projected.length, before,
          reason: 'Scrolling retained rows must not fetch another page');
      screen.chat.scrollToTail();
      screen.chat.scrollBy(-screen.chat.contentRows);
      expect(projected.length, greaterThan(before));
      expect(projected.skip(before).first, lessThan(firstSeq));
      expect(view.blocks.singleWhere((b) => b.kind == ChatBlockKind.reasoning)
          .folded, isFalse);
      expect(screen.chat.isTailPinned, isFalse);
      final offset = screen.chat.debugScrollOffset;
      // Prepending a page preserves the distance from the tail, then the
      // requested line scroll moves exactly one more row into that history.
      screen.chat.scrollBy(-1);
      expect(screen.chat.debugScrollOffset, offset + 1);
      screen.resize(ScreenLayout.fromSize(60, 18, split: false));
      view.repaintConsole();
      expect(screen.chat.isTailPinned, isFalse);
      screen.chat.scrollToTail();
      await host.send('continue');
      await Future<void>.delayed(Duration.zero);
      final transcript = screen.chat.snapshotLines().join('\n');
      expect('live reply'.allMatches(transcript), hasLength(1));
      expect('continue'.allMatches(transcript), hasLength(1));
      view.detachConsole();
      expect(screen.chat.onHistoryRequested, isNull);
      view.attachConsole(context);
      expect('live reply'.allMatches(screen.chat.snapshotLines().join('\n')),
          hasLength(1));
    });
  }
}
