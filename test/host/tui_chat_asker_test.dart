import 'dart:async';

import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/pipeline/workflow_permission_asker.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

// The chat asker is the approval path users actually see, and it had no key
// matrix — which is how it came to print a deny key on the sandbox-access prompt
// that did nothing. These tests drive it the way it is driven live: feed a byte,
// read the answer.

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;
  late TuiConversationHost host;

  setUp(() {
    io = FakeStdio();
    screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(160, 30),
      ansi: AnsiCapable.yes,
    );
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    host = TuiConversationHost(
      conversationId: 'test',
      chat: screen.chat,
      screen: screen,
      editor: editor,
      spinner: Spinner(enabled: false, region: screen.status),
      primary: true,
    );
    host.setActive(true);
  });

  tearDown(() => editor.close());

  /// Answer [prompt] with [keys] and return what the asker decided.
  Future<PermissionResponse> answer(PermissionPrompt prompt, List<int> keys) async {
    final pending = host.askPermission(prompt);
    await _flush();
    io.feedBytes(keys);
    return pending.timeout(const Duration(seconds: 2));
  }

  PermissionPrompt bashPrompt() =>
      PermissionPrompt('bash', const {'command': 'dart test'});

  PermissionPrompt sandboxPrompt() => PermissionPrompt(
        'bash',
        const {'command': 'dart test'},
        sandboxAccess: SandboxAccessRequest(['/sdk/cache'], 'launcher metadata'),
      );

  PermissionPrompt outsidePrompt() => PermissionPrompt(
        'write',
        const {'filePath': '/p/a.dart'},
        outsideSandbox: true,
      );

  /// What the asker printed, with the escape bytes dropped.
  String output() => io.written
      .toString()
      .replaceAll('\x1b[1A\x1b[2K', '')
      .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '');

  group('the row the user sees is the list they can answer', () {
    test('every advertised key answers with its own choice', () async {
      // Ordinary prompt: four answers, including deny-once, which used to work
      // but be advertised nowhere.
      for (final (key, decision, remember) in const [
        (0x79, PermissionDecision.allow, false), // y
        (0x6e, PermissionDecision.deny, false), // n
        (0x61, PermissionDecision.allow, true), // a
        (0x64, PermissionDecision.deny, true), // d
      ]) {
        final response = await answer(bashPrompt(), [key]);
        expect(response.decision, decision,
            reason: 'key ${String.fromCharCode(key)}');
        expect(response.remember, remember,
            reason: 'key ${String.fromCharCode(key)}');
      }
    });

    test('the ordinary row advertises all four answers', () {
      final row = PermissionPrompt('bash', const {'command': 'dart test'})
          .approvalOptionsText;
      for (final key in ['[y]', '[n]', '[a]', '[d]']) {
        expect(row, contains(key));
      }
      expect(row, contains('deny once'));
      expect(row, contains('deny always'));
    });

    test('a sandbox prompt denies on its advertised key, and on Enter',
        () async {
      // The regression this matrix exists for: the row used to advertise
      // `[d] deny` while `d` was ignored and Enter on the highlighted "deny" did
      // nothing at all. The advertised key is `n`, and both routes work.
      final prompt = sandboxPrompt();
      expect(prompt.approvalOptionsText, contains('[n] deny'));
      expect(prompt.approvalOptionsText, isNot(contains('[d]')));
      expect((await answer(prompt, [0x6e])).decision, PermissionDecision.deny);

      final viaEnter = host.askPermission(sandboxPrompt());
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x42]); // down arrow: y -> a
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x42]); // down again: a -> n
      await _flush();
      io.feedBytes([0x0d]); // Enter
      final response = await viaEnter.timeout(const Duration(seconds: 2));
      expect(response.decision, PermissionDecision.deny);
      expect(response.remember, isFalse,
          reason: 'denying the directory request must not remember an allow');
    });

    test('a key the prompt does not offer is ignored, not guessed at',
        () async {
      // `d` on a sandbox prompt: the first one gets the one-shot ack and the
      // asker keeps waiting.
      final pending = host.askPermission(sandboxPrompt());
      await _flush();
      io.feedBytes([0x64]); // 'd'
      await _flush();
      expect(editor.isReadingKey, isTrue, reason: 'the read stays armed');
      expect(output(), contains('…'));
      expect(output(), isNot(contains('d\n')),
          reason: 'an unoffered key is never echoed as an answer');

      io.feedBytes([0x79]); // 'y' — a real answer still lands
      expect((await pending.timeout(const Duration(seconds: 2))).decision,
          PermissionDecision.allow);
    });

    for (final workflow in [false, true]) {
      test('wheel and arrow bursts do not append approvals workflow=$workflow', () async {
        final ask = workflow
            ? WorkflowPermissionAsker(sink: host, screen: screen, editor: editor).ask
            : host.askPermission;
        final pending = ask(bashPrompt());
        await _flush();
        final rows = screen.chat.contentRows;
        for (var i = 0; i < 20; i++) {
          editor.inject(ScrollEvent(up: i.isEven));
          await _flush();
        }
        expect(screen.chat.contentRows, rows,
            reason: 'wheel events scroll the card without appending transcript rows');
        for (var i = 0; i < 20; i++) {
          editor.inject(ArrowKey(i.isEven ? ArrowDirection.down : ArrowDirection.up));
          await _flush();
        }
        expect(screen.chat.contentRows, rows,
            reason: 'arrows change the overlay, never append transcript rows');
        expect(editor.isReadingKey, isTrue);
        editor.inject(ControlKey(ControlCode.enter));
        expect((await pending.timeout(const Duration(seconds: 2))).decision, PermissionDecision.allow);
      });
    }

    test('arrow selection moves the highlighted answer', () async {
      final pending = host.askPermission(bashPrompt());
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x42]); // down: [y] -> [n]
      await _flush();
      io.feedBytes([0x0d]); // Enter confirms the highlighted answer
      final response = await pending.timeout(const Duration(seconds: 2));
      expect(response.decision, PermissionDecision.deny);
      expect(response.remember, isFalse);
    });

    test('an outside-sandbox answer records its decision', () async {
      // Pressing d used to answer without echoing or terminating the row.
      final response = await answer(outsidePrompt(), [0x64]);
      expect(response.decision, PermissionDecision.deny);
      expect(response.remember, isFalse,
          reason: 'outside-sandbox prompts have no deny-always');
      expect(output(), contains('· deny'));
    });

    test('an outside-sandbox allow-for-session carries its own scope', () async {
      final response = await answer(outsidePrompt(), [0x61]);
      expect(response.decision, PermissionDecision.allow);
      expect(response.remember, isTrue);
      expect(response.scope, GrantScope.sessionOutside);
    });

    test('a sandbox directory grant carries its own scope', () async {
      final response = await answer(sandboxPrompt(), [0x61]);
      expect(response.remember, isTrue);
      expect(response.scope, GrantScope.sessionDirectories);
    });

    test('a background conversation refuses without blaming the user', () async {
      // The refusal is this conversation being off screen, not a decision the
      // user made; the approval audit line says so.
      host.setActive(false);
      final response = await answer(bashPrompt(), [0x79]);
      expect(response.decision, PermissionDecision.deny);
      expect(response.decidedBy, 'background');
      expect(response.note, contains('auto-refused'));
    });

    test('the sandbox chip states the posture, and is absent when confined', () {
      expect(sandboxOffChip(null), isNull);
      final chip = sandboxOffChip('bwrap not found on PATH');
      expect(chip, contains('[sandbox: off]'));
      expect(chip, contains('bwrap not found on PATH'));
      // --yolo gets its own wording so the user knows who turned it off.
      expect(sandboxOffChip(kSandboxOffReasonYolo), contains('--yolo'));
    });

    test('an ordinary "always" is conversation-scoped, and says so', () async {
      final prompt = bashPrompt();
      final response = await answer(prompt, [0x61]);
      expect(response.scope, GrantScope.conversation);
      // The prompt states the rule it will remember, not just the scope.
      expect(output(), contains('dart test'));
      expect(prompt.alwaysScopeNote, contains('this conversation'));
    });
  });
}
