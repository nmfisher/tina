// Tests for the /blocks /show /hide command semantics, extracted out of the
// coordinator closure factory into lib/tui/transcript_fold.dart. These are
// the command's contract: which blocks are foldable, the 1-based numbering
// users see, the all/list forms, and the no-op wording that never flips a
// block the wrong way.
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import 'package:tina/chat/chat_agent_sink.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/tui/transcript_fold.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

void main() {
  late _RecordingHost host;
  // A local fn, not a getter: Dart has no local getters, and a `T get x =>`
  // line inside a body parses as a function declaration.
  ChatAgentSink sink() => host.transcript;

  setUp(() {
    host = _RecordingHost();
  });

  /// One completed tool call — a foldable block: a one-line header plus the
  /// retained output behind it. Tool rows start folded.
  void toolCall(String name, Map<String, dynamic> input, String output) {
    sink().toolStart(ToolStartEvent(name, name, input));
    sink().toolComplete(
      ToolCompleteEvent(name, name, isError: false, result: output),
    );
  }

  void bash(String command, {String output = 'hit'}) =>
      toolCall('bash', {'command': command}, output);

  group('foldTranscriptCommand', () {
    test('list reports nothing on an empty transcript', () async {
      await foldTranscriptCommand(host, verb: 'list', argument: '');
      expect(host.messages.single, 'nothing to fold yet.\n');
    });

    test(
      'list numbers only foldable blocks, from 1, with the marker',
      () async {
        // Prose and the user's own words never fold — numbering must skip
        // them rather than offering a /show that cannot work.
        sink().userMessage('do the thing');
        bash('grep -rn todo lib');
        sink().text('the answer is 42');
        sink().newline();

        await foldTranscriptCommand(host, verb: 'list', argument: '');
        final out = host.messages.single;
        expect(out, startsWith('foldable blocks:\n'));
        // The row carries the block's own one-line form: marker, then the
        // summary (arrow glyph + subject + outcome).
        expect(out, contains('1. ▸ → bash · grep -rn todo lib  ok'));
        expect(out, contains('/show <n> reveals one, /hide <n> closes it'));
        // Neither the user block nor the prose block is offered.
        expect(out, isNot(contains('do the thing')));
        expect(out, isNot(contains('the answer is 42')));
        expect(
          out.split('\n').where((l) => l.contains('  ')).length,
          2,
          reason: 'exactly one foldable row plus the trailing hint line',
        );
      },
    );

    test(
      'show reveals a folded block; show again reports it is open',
      () async {
        bash('ls lib');
        final block = sink().blocks.firstWhere((b) => b.canFold);
        expect(block.folded, isTrue, reason: 'a tool row starts folded');

        await foldTranscriptCommand(host, verb: 'show', argument: '1');
        expect(block.folded, isFalse);
        expect(host.messages.single, 'block 1 revealed.\n');

        host.messages.clear();
        await foldTranscriptCommand(host, verb: 'show', argument: '1');
        expect(block.folded, isFalse, reason: 'a second show is a no-op');
        expect(host.messages.single, 'block 1 is already open.\n');
      },
    );

    test('hide folds an open block; hide again reports it is folded', () async {
      bash('ls lib');
      final block = sink().blocks.firstWhere((b) => b.canFold);
      await foldTranscriptCommand(host, verb: 'show', argument: '1');
      host.messages.clear();

      await foldTranscriptCommand(host, verb: 'hide', argument: '1');
      expect(block.folded, isTrue);
      expect(host.messages.single, 'block 1 folded.\n');

      host.messages.clear();
      await foldTranscriptCommand(host, verb: 'hide', argument: '1');
      expect(block.folded, isTrue);
      expect(host.messages.single, 'block 1 is already folded.\n');
    });

    test(
      'all folds every block and reports the count; show all reverses it',
      () async {
        // Tool rows start folded, so reveal first and then the hide-all is a
        // real change in both directions.
        bash('ls', output: 'a');
        bash('cat b', output: 'b');
        toolCall('read', {'file_path': 'lib/x.dart'}, 'contents');
        await foldTranscriptCommand(host, verb: 'show', argument: 'all');
        host.messages.clear();

        await foldTranscriptCommand(host, verb: 'hide', argument: 'all');
        final foldable = sink().blocks.where((b) => b.canFold).length;
        expect(foldable, 3, reason: 'three tool rows, each with a body');
        expect(sink().blocks.where((b) => b.canFold && b.folded).length, 3);
        expect(host.messages.single, '3 blocks folded.\n');

        host.messages.clear();
        await foldTranscriptCommand(host, verb: 'show', argument: 'all');
        expect(sink().blocks.where((b) => b.canFold && b.folded).length, 0);
        expect(host.messages.single, '3 blocks revealed.\n');
      },
    );

    test('all on an already-folded transcript says nothing to fold', () async {
      bash('ls', output: 'a');
      bash('cat b', output: 'b');
      await foldTranscriptCommand(host, verb: 'hide', argument: 'all');
      host.messages.clear();
      await foldTranscriptCommand(host, verb: 'hide', argument: 'all');
      expect(host.messages.single, 'nothing to fold.\n');

      await foldTranscriptCommand(host, verb: 'show', argument: 'all');
      host.messages.clear();
      await foldTranscriptCommand(host, verb: 'show', argument: 'all');
      expect(host.messages.single, 'nothing to unfold.\n');
    });

    test('all skips blocks that cannot fold', () async {
      // A tool call with no retained output has no body: it cannot fold, so
      // the count must exclude it rather than claim a change that did not
      // happen.
      sink().userMessage('hello');
      toolCall('read', {'file_path': 'lib/x.dart'}, '');

      await foldTranscriptCommand(host, verb: 'hide', argument: 'all');
      expect(host.messages.single, 'nothing to fold.\n');
    });

    test('a bad index names the valid range instead of folding', () async {
      bash('ls lib', output: 'a');

      for (final arg in ['0', '2', 'wat', '']) {
        host.messages.clear();
        await foldTranscriptCommand(host, verb: 'show', argument: arg);
        expect(
          host.messages.single,
          'no block $arg — /blocks lists 1 foldable block.\n',
          reason: 'argument "$arg"',
        );
        expect(
          sink().blocks.firstWhere((b) => b.canFold).folded,
          isTrue,
          reason: 'a rejected index must not touch the block',
        );
      }
    });

    test('the 1-based number maps past an unfoldable leading block', () async {
      // The numbering the user sees is over FOLDABLE blocks only, so "1"
      // must land on the tool call even with a user block in front of it.
      sink().userMessage('first');
      bash('cat out');

      await foldTranscriptCommand(host, verb: 'show', argument: '1');
      expect(host.messages.single, 'block 1 revealed.\n');
      expect(sink().blocks.firstWhere((b) => b.canFold).folded, isFalse);
    });
  });
}

Screen _backgroundScreen() => Screen(
  io: FakeStdio()..columns = 120,
  layout: ScreenLayout.fromSize(120, 24),
);

/// Records [showMessage] calls so the command's replies are assertable
/// without a rendered screen.
class _RecordingHost extends TuiConversationHost {
  _RecordingHost()
    : super(
        conversationId: 'fold-test',
        chat: ScrollingTextRegion(_backgroundScreen())..detach(),
        spinner: Spinner(enabled: false),
        screen: _backgroundScreen(),
        primary: false,
      );

  final List<String> messages = <String>[];

  @override
  void showMessage(
    String message, {
    HostMessageStyle style = HostMessageStyle.normal,
  }) {
    messages.add(message);
  }
}
