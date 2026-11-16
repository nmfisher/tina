import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel_tui/tina_channel_tui.dart';
import 'package:tina_console/tina_console.dart';

import 'support/console_fixture.dart';

/// The pane is presentation over the store interface: these tests drive
/// an in-memory store (the wasm seam twin), so nothing here links
/// sqlite. The composer and renderer are pure; the view test attaches
/// a real LineEditor/Screen pair headlessly to prove key routing.
/// humanJoin/humanPost live in tina_channel (join/post semantics for
/// the human identity) and are exercised there too.
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

  group('renderChannelPane input line', () {
    List<String> render(ChannelInputLine? input,
            {String? self, int width = 60}) =>
        renderChannelPane(
          channels: const [],
          unread: const {},
          selected: '#lobby',
          messages: const [],
          members: const [],
          width: width,
          height: 8,
          self: self,
          input: input,
        );

    test('composing shows the draft with a cursor; browsing hides the line',
        () {
      expect(render(const ChannelInputLine(draft: 'hello')).join('\n'),
          contains('❯ hello▌'));
      expect(render(null).join('\n'), isNot(contains('❯')));
      // Placeholder instead of a dangling cursor on an empty draft.
      expect(render(const ChannelInputLine()).join('\n'), contains('❯ message…▌'));
    });

    test('a long draft clips its tail so typing stays visible', () {
      final lines = render(ChannelInputLine(draft: 'a' * 100), width: 20);
      expect(lines.last, '❯ ${'a' * 17}▌');
    });

    test('a disabled input line renders the one-line hint', () {
      final text = render(const ChannelInputLine(
              disabledHint: 'input unavailable — use tina channel say'))
          .join('\n');
      expect(text, contains('input unavailable'));
      expect(text, isNot(contains('❯')));
    });

    test('the post error renders above the input line', () {
      final lines =
          render(const ChannelInputLine(draft: 'kept', error: 'store gone'));
      expect(lines.join('\n'), contains('! store gone'));
      expect(lines.last, contains('❯ kept▌'));
    });

    test('presence marks the human as (you)', () {
      final store = InMemoryChannelStore();
      store.setMember('#lobby', 'calm-heron', status: 'working');
      humanJoin(store, '#lobby', 'sam', <String>{});
      final lines = renderChannelPane(
        channels: store.listChannels(),
        unread: const {},
        selected: '#lobby',
        messages: const [],
        members: store.members('#lobby'),
        width: 60,
        height: 10,
        self: 'sam',
      );
      expect(lines.join('\n'),
          allOf(contains('calm-heron working'), contains('sam (you)')));
    });
  });

  group('ChannelComposer', () {
    String? Function(String text) postTo(InMemoryChannelStore store,
        Set<String> joined,
        {String channel = '#lobby',
        String name = 'sam'}) {
      return (String text) => humanPost(store,
          channel: channel, name: name, text: text, joined: joined);
    }

    void type(ChannelComposer composer, String text,
        String? Function(String text) post) {
      for (final rune in text.runes) {
        expect(
            composer.handle(
                CharInput(String.fromCharCode(rune)), post: post),
            isTrue,
            reason: 'typing "$text" is consumed');
      }
    }

    test('typing builds a draft; Enter posts as the human with mentions',
        () {
      final store = InMemoryChannelStore();
      final joined = <String>{};
      final composer = ChannelComposer(canPost: true);
      final post = postTo(store, joined);

      type(composer, 'hi @calm-heron', post);
      expect(composer.draft, 'hi @calm-heron');

      expect(composer.handle(ControlKey(ControlCode.enter), post: post),
          isTrue);
      expect(composer.draft, '');
      expect(composer.error, isNull);

      final messages = store.read('#lobby');
      expect(messages.last.sender, 'sam');
      expect(messages.last.text, 'hi @calm-heron');
      expect(messages.last.mentions, ['calm-heron']);
      // Posting joined the channel: the human is present alongside
      // agents, as a member row.
      final member = store.members('#lobby').singleWhere((m) => m.name == 'sam');
      expect(member.role, 'human');
    });

    test('backspace edits, killToStart clears, paste flattens', () {
      final composer = ChannelComposer(canPost: true);
      String? post(String text) => null;
      type(composer, 'hello', post);
      expect(composer.handle(ControlKey(ControlCode.backspace), post: post),
          isTrue);
      expect(composer.draft, 'hell');
      expect(
          composer.handle(
              PasteInput('multi\nline   paste'), post: post),
          isTrue);
      expect(composer.draft, 'hell multi line paste');
      expect(
          composer
              .handle(EditingKey(EditingAction.killToStart), post: post),
          isTrue);
      expect(composer.draft, '');
    });

    test('a failed post keeps the draft and surfaces the error', () {
      final composer = ChannelComposer(canPost: true);
      type(composer, 'retry me', (text) => 'store gone');
      expect(
          composer.handle(ControlKey(ControlCode.enter),
              post: (text) => 'store gone'),
          isTrue);
      expect(composer.draft, 'retry me');
      expect(composer.error, 'store gone');
    });

    test('Enter on an empty draft posts nothing but is still consumed', () {
      final composer = ChannelComposer(canPost: true);
      String? post(String text) => fail('must not post: "$text"');
      // Enter while merely browsing is not an input key; in input mode
      // an empty draft is consumed but sends nothing.
      expect(composer.handle(ControlKey(ControlCode.enter), post: post),
          isFalse);
      composer.activate();
      expect(composer.handle(ControlKey(ControlCode.enter), post: post),
          isTrue);
      expect(composer.draft, '');
    });

    test('Esc exits input mode keeping the draft; typing resumes', () {
      final composer = ChannelComposer(canPost: true);
      String? post(String text) => null;
      type(composer, 'ab', post);
      expect(composer.handle(EscapeKey(), post: post), isTrue);
      expect(composer.isActive, isFalse);
      expect(composer.draft, 'ab');
      expect(composer.handle(CharInput('c'), post: post), isTrue);
      expect(composer.isActive, isTrue);
      expect(composer.draft, 'abc');
    });

    test('inactive, the composer declines browse keys', () {
      final composer = ChannelComposer(canPost: true);
      String? post(String text) => fail('must not post');
      expect(composer.handle(ArrowKey(ArrowDirection.down), post: post),
          isFalse);
      expect(
          composer.handle(
              ControlKey(ControlCode.enter), post: post),
          isFalse);
      expect(composer.handle(ScrollEvent(up: true), post: post), isFalse);
    });

    test('without a post path the composer never activates', () {
      final composer = ChannelComposer(canPost: false);
      var postCalls = 0;
      expect(
          composer.handle(CharInput('x'), post: (text) {
            postCalls++;
            return null;
          }),
          isFalse);
      expect(composer.isActive, isFalse);
      expect(postCalls, 0);
    });
  });

  group('humanJoin', () {
    test('announces the first join per channel, later touches are silent',
        () {
      final store = InMemoryChannelStore();
      final joined = <String>{};
      humanJoin(store, '#lobby', 'sam', joined);
      final statusRows = store
          .read('#lobby')
          .where((m) => m.type == ChannelMessageType.status)
          .toList();
      expect(statusRows, isNotEmpty);
      expect(statusRows.last.text, 'joined');

      humanJoin(store, '#lobby', 'sam', joined);
      expect(
          store
              .read('#lobby')
              .where((m) => m.type == ChannelMessageType.status)
              .length,
          statusRows.length);
    });
  });

  group('ChannelPaneView (headless console)', () {
    late Io io;
    late Screen screen;
    late LineEditor editor;
    late InMemoryChannelStore store;
    late ChannelPaneView view;
    late ConsoleAttachment attachment;

    setUp(() {
      io = Io();
      screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24, split: false),
      );
      editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      // Two Esc presses inside the app's 450 ms double-Esc window are the
      // global force-cancel gesture (it also closes active modals). Shrink
      // the window so the pane's own Esc ladder — exit input, then close —
      // is what these presses exercise.
      LineEditor.debugDoubleEscWindow = Duration.zero;
      // A pending read arms the editor's input path, as in a live app.
      unawaited(editor.readLine('> '));
      store = InMemoryChannelStore();
      view = ChannelPaneView(store, humanName: 'sam');
      attachment = ConsoleAttachment.attach(
        view,
        ConsoleContext(screen: screen, editor: editor).forView(
          chat: screen.chat,
          isActive: () => true,
          activate: () {},
          panels: Panels(),
        ),
      );
    });

    tearDown(() {
      LineEditor.debugDoubleEscWindow = null;
      attachment.dispose();
      editor.close(reportLatency: false);
      screen.dispose();
      unawaited(io.input.close());
    });

    // Injected events ride the input stream, so each keystroke needs a
    // queue pump before its effects are visible.
    Future<void> key(InputEvent event) async {
      editor.inject(event);
      await pumpEventQueue();
    }

    test('typing posts through the pane; Esc exits input then closes; ' +
        'a closed pane leaves the app keys alone', () async {
      // Closed pane: typing reaches the chat editor (global keys flow).
      await key(CharInput('z'));
      expect(editor.draftText, 'z');

      // Open: composing from the first keystroke.
      view.openPane();
      expect(view.isOpen, isTrue);
      expect(view.inputActive, isTrue);
      await key(CharInput('hi '));
      await key(CharInput('@calm-heron'));
      expect(editor.draftText, 'z'); // the pane consumed the typing
      expect(view.visibleLines.join('\n'), contains('❯ hi @calm-heron▌'));

      // Enter posts as the human, and the pane renders the new row.
      await key(ControlKey(ControlCode.enter));
      final messages = store.read('#lobby');
      expect(messages.last.sender, 'sam');
      expect(messages.last.text, 'hi @calm-heron');
      expect(messages.last.mentions, ['calm-heron']);
      expect(view.visibleLines.join('\n'), contains('hi @calm-heron'));

      // The human joined: presence shows "you" alongside agents.
      store.setMember('#lobby', 'calm-heron', status: 'working');
      view.repaintConsole();
      expect(view.visibleLines.join('\n'), contains('sam (you)'));

      // Esc exits input mode; the cursor line disappears, the pane stays.
      await key(EscapeKey());
      expect(view.inputActive, isFalse);
      expect(view.isOpen, isTrue);
      expect(view.visibleLines.join('\n'), isNot(contains('▌')));

      // Esc again closes; typing is the app's again.
      await key(EscapeKey());
      expect(view.isOpen, isFalse);
      await key(CharInput('y'));
      expect(editor.draftText, 'zy');
    });

    test('a null human identity renders the input line disabled', () {
      final readonly = ChannelPaneView(InMemoryChannelStore());
      addTearDown(readonly.detachConsole);
      readonly.attachConsole(
        ConsoleContext(screen: screen, editor: editor).forView(
          chat: screen.chat,
          isActive: () => true,
          activate: () {},
          panels: Panels(),
        ),
      );
      readonly.openPane();
      expect(readonly.inputActive, isFalse);
      expect(readonly.visibleLines.join('\n'),
          contains('input unavailable'));
    });

    test('below the column threshold the pane is the full-screen dialog',
        () async {
      // 80 cols is under the side column's 96-col threshold: opening
      // the pane reserves nothing and the browser keeps today's
      // geometry — the conversation's dialog area.
      view.openPane();
      await pumpEventQueue();
      expect(screen.layout.rightColumn, isEmpty);
      expect(screen.layout.chat.width, 78);
      expect(dialogArea(screen.layout).width, 78);
      expect(view.visibleLines, isNotEmpty);
      await key(EscapeKey()); // exit input mode
      await key(EscapeKey()); // close the pane
      expect(view.isOpen, isFalse);
    });
  });

  group('ChannelPaneView side column (120-col terminal)', () {
    late Io io;
    late Screen screen;
    late LineEditor editor;
    late InMemoryChannelStore store;
    late ChannelPaneView view;
    late ConsoleAttachment attachment;

    setUp(() {
      io = Io();
      // 120 cols: the side column applies (threshold 96) and claims
      // a third of the width — 40 columns — at the right edge.
      screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 30, split: false),
      );
      editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      LineEditor.debugDoubleEscWindow = Duration.zero;
      unawaited(editor.readLine('> '));
      store = InMemoryChannelStore();
      view = ChannelPaneView(store, humanName: 'sam');
      attachment = ConsoleAttachment.attach(
        view,
        ConsoleContext(screen: screen, editor: editor).forView(
          chat: screen.chat,
          isActive: () => true,
          activate: () {},
          panels: Panels(),
        ),
      );
    });

    tearDown(() {
      LineEditor.debugDoubleEscWindow = null;
      attachment.dispose();
      editor.close(reportLatency: false);
      screen.dispose();
      unawaited(io.input.close());
    });

    Future<void> key(InputEvent event) async {
      editor.inject(event);
      await pumpEventQueue();
    }

    test('an open pane renders inside the column; the input line works '
        'at column width; closing releases the reservation', () async {
      // Closed pane: no reservation.
      expect(screen.layout.rightColumn, isEmpty);

      view.openPane();
      await pumpEventQueue();
      // The conversation narrows by the column: 40 cols at the right.
      expect(screen.layout.rightColumn.width, 40);
      expect(screen.layout.rightColumn.col, 80);
      expect(screen.layout.chat.width, 78);

      // The pane's lines render inside the column width — even a
      // long message wraps/clips at 40, never reaching the dialog
      // area's 78.
      store.post('#lobby', sender: 'a', text: 'x' * 200);
      view.repaintConsole();
      await pumpEventQueue();
      expect(view.visibleLines, isNotEmpty);
      for (final line in view.visibleLines) {
        expect(plainWidth(line), lessThanOrEqualTo(40),
            reason: 'pane lines stay inside the 40-col column');
      }

      // The input line is usable at column width: typing composes and
      // Enter posts, all within the strip.
      await key(CharInput('hi @calm-heron'));
      expect(view.visibleLines.join('\n'), contains('❯ hi @calm-heron▌'));
      await key(ControlKey(ControlCode.enter));
      expect(store.read('#lobby').last.text, 'hi @calm-heron');
      for (final line in view.visibleLines) {
        expect(plainWidth(line), lessThanOrEqualTo(40));
      }

      // Esc drops out of input mode; Esc again closes the pane and the
      // reservation goes with it — the conversation is whole again.
      await key(EscapeKey());
      await key(EscapeKey());
      expect(view.isOpen, isFalse);
      await pumpEventQueue();
      expect(screen.layout.rightColumn, isEmpty);
      expect(screen.layout.chat.width, 118);
    });
  });
}
