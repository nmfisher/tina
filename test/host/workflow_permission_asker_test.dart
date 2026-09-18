import 'dart:async';

import 'package:tina/pipeline/workflow_permission_asker.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_stdio.dart';

PermissionPrompt _bashPrompt(String command) =>
    PermissionPrompt('bash', {'command': command});

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

void main() {
  for (final conversation in [false, true]) {
    for (final drafting in [false, true]) {
      test('cancel releases approval conversation=$conversation drafting=$drafting', () async {
        final io = FakeStdio();
        final screen = Screen(io: io, layout: ScreenLayout.fromSize(160, 30), ansi: AnsiCapable.yes);
        final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
        addTearDown(editor.close);
        final host = TuiConversationHost(conversationId: 'test',
            chat: screen.chat, screen: screen, editor: editor,
            spinner: Spinner(enabled: false, region: screen.status), primary: true);
        host.setActive(true);
        final workflow = WorkflowPermissionAsker(sink: FakeAgentSink(), screen: screen, editor: editor);
        final ask = conversation ? host.askPermission : workflow.ask;
        if (drafting) {
          unawaited(editor.readLine('> '));
          await _flush();
          io.feedBytes([0x78]);
          await _flush();
        }
        final cancel = Completer<void>();
        final pending = ask(PermissionPrompt('bash', const {'command': 'dart test'},
            outsideSandbox: true, cancelSignal: cancel.future));
        await _flush();
        cancel.complete();
        expect((await pending.timeout(const Duration(seconds: 2))).decision, PermissionDecision.deny);
        expect(editor.isReadingKey, isFalse);
        if (drafting) {
          expect(editor.editState.buffer, 'x');
          io.feedBytes([0x0d]);
          await _flush();
        }
        // An abandoned read must not capture the next prompt's answer.
        final next = ask(_bashPrompt('next'));
        await _flush();
        io.feedBytes([0x79]);
        expect((await next.timeout(const Duration(seconds: 2))).decision, PermissionDecision.allow);
      });
    }
  }

  test('cancelled queued read leaves the current keyboard owner intact', () async {
    final io = FakeStdio();
    final screen = Screen(io: io, layout: ScreenLayout.fromSize(160, 30), ansi: AnsiCapable.yes);
    final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    addTearDown(editor.close);
    final owner = editor.readKey();
    await _flush();
    final cancel = Completer<void>();
    final queued = editor.readKey(globalKeys: true, cancelSignal: cancel.future);
    cancel.complete();
    expect(await queued, ControlKey(ControlCode.ctrlC));
    expect(editor.isReadingKey, isTrue);
    io.feedBytes([0x79]);
    expect(await owner, CharInput('y'));
  });

  for (final conversation in [false, true]) {
    for (final (keys, decision, remember) in [
      ([0x79], PermissionDecision.allow, false),
      ([0x64], PermissionDecision.deny, false),
      ([0x61], PermissionDecision.allow, true),
      ([0x1b, 0x5b, 0x42, 0x0d], PermissionDecision.allow, true),
      ([0x1b, 0x5b, 0x42, 0x1b, 0x5b, 0x42, 0x0d], PermissionDecision.deny, false),
      // 0x03 removed: Ctrl+C is the quit flow in the editor and can no longer
      // settle an approval as a deny; Esc (0x1b) is the deny gesture.
    ]) {
      test('outside approval conversation=$conversation keys=$keys', () async {
        final io = FakeStdio();
        final screen = Screen(io: io, layout: ScreenLayout.fromSize(160, 30), ansi: AnsiCapable.yes);
        final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
        final sink = FakeAgentSink();
        final host = TuiConversationHost(conversationId: 'test',
            chat: screen.chat, screen: screen, editor: editor,
            spinner: Spinner(enabled: false, region: screen.status), primary: true);
        host.setActive(true);
        final workflow = WorkflowPermissionAsker(sink: sink, screen: screen, editor: editor);
        final prompt = PermissionPrompt('bash', const {'command': 'dart test'},
            outsideSandbox: true, retryExplanation: 'Read-only file system');
        final pending = conversation ? host.askPermission(prompt) : workflow.ask(prompt);
        await _flush();
        final output = conversation ? io.written.toString() : sink.notices.map((n) => n.message).join();
        expect(output, contains('definitely OK'));
        expect(output, contains('run outside sandbox once'));
        expect(output, contains('outside for session'));
        expect(output, isNot(contains('allow always')));
        if (keys.length == 7) {
          io.feedBytes(keys.sublist(0, 3));
          await _flush();
          io.feedBytes(keys.sublist(3));
        } else {
          io.feedBytes(keys);
        }
        final result = await pending.timeout(const Duration(seconds: 2));
        expect(result.decision, decision);
        expect(result.remember, remember);
        editor.close();
      });
    }
  }

  for (final (key, decision, remember) in [
    (0x79, PermissionDecision.allow, false),
    (0x61, PermissionDecision.allow, true),
    (0x6e, PermissionDecision.deny, false),
    (0x1b, PermissionDecision.deny, false),
    // 0x03 removed: Ctrl+C is the quit flow and no longer denies approvals.
  ]) {
    test('directory approval displays authority and handles key $key', () async {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 24),
        ansi: AnsiCapable.yes,
      );
      final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      final sink = FakeAgentSink();
      final asker = WorkflowPermissionAsker(
        sink: sink,
        screen: screen,
        editor: editor,
      );
      final prompt = PermissionPrompt(
        'bash',
        const {'command': 'dart test'},
        sandboxAccess: SandboxAccessRequest([
          '/sdk/cache',
        ], 'launcher metadata'),
        retryExplanation:
            'The command failed writing /sdk/cache/stamp: Read-only file system.',
        retrySafety: 'Checked the launcher output; tests never started.',
      );
      final pending = asker.ask(prompt);
      await _flush();
      final notices = sink.notices.map((n) => n.message).join('\n');
      expect(notices, contains('/sdk/cache'));
      expect(notices, contains('launcher metadata'));
      expect(notices, contains('Read-only file system'));
      expect(notices, contains('tests never started'));
      expect(notices, contains('so the command can be retried'));
      expect(notices, contains('[a] session directories'));
      expect(notices, isNot(contains('[d]eny always')));
      // The old deny-always shortcut must not silently install a command rule.
      io.feedBytes([0x64]);
      await _flush();
      expect(editor.isReadingKey, isTrue);
      io.feedBytes([key]);
      final response = await pending.timeout(const Duration(seconds: 2));
      expect(response.decision, decision);
      expect(response.remember, remember);
      editor.close();
    });
  }

  test(
    'askPermission readKey waits while the user is typing a prompt',
    () async {
      // Live repro (80x24, real provider): the env ceremony's first approval
      // armed while the user was still typing their prompt; the prompt's Enter
      // answered the approval as a deny (not y/a/d) and the prompt was never
      // submitted. The asker must wait for the in-flight readLine to submit
      // before arming its readKey.
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.yes,
      );
      final ed = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      final sink = FakeAgentSink();
      final asker = WorkflowPermissionAsker(
        sink: sink,
        screen: screen,
        editor: ed,
      );

      // The user is typing a prompt (readLine pending) when the approval lands.
      final line = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61]); // 'a'
      await _flush();
      final ask = asker.ask(_bashPrompt('ls -la'));
      await _flush();

      // The approval's readKey is not armed yet — it must wait for the submit.
      expect(
        ed.isReadingKey,
        isFalse,
        reason: 'approval must not arm while the user is typing',
      );

      // The Enter submits the user's prompt — it must NOT answer the approval.
      io.feedBytes([0x0d]);
      final submitted = await line.timeout(const Duration(seconds: 2));
      expect(submitted, 'a', reason: 'the prompt must submit, not be eaten');

      // Now the approval arms and the next key answers it.
      await _flush();
      expect(ed.isReadingKey, isTrue);
      io.feedBytes([0x79]); // 'y'
      final response = await ask.timeout(const Duration(seconds: 2));
      expect(response, PermissionResponse.allowOnce);
    },
  );

  test(
    'empty pending readLine does not stall the approval (no deadlock)',
    () async {
      // The TUI input loop ALWAYS sits in readLine — the moment a prompt
      // submits, the next readLine arms (empty). If the approval waited on any
      // pending readLine, every approval deadlocked behind the user's next
      // prompt: live repro at 80x24 — 22 queued 'y's, the approval never
      // armed, the turn stalled forever. Only a readLine WITH unsent content
      // (the user mid-typing) defers the approval.
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.yes,
      );
      final ed = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      final asker = WorkflowPermissionAsker(
        sink: FakeAgentSink(),
        screen: screen,
        editor: ed,
      );

      // The input loop's next readLine is pending, empty. The call itself
      // is the setup (a pending readLine); its future is intentionally
      // dropped.
      ed.readLine('> ');
      await _flush();

      // The approval must arm immediately, not wait for `next`.
      final ask = asker.ask(_bashPrompt('git status'));
      await _flush();
      expect(
        ed.isReadingKey,
        isTrue,
        reason: 'an empty pending readLine must not stall the approval',
      );

      // The first key answers it.
      io.feedBytes([0x79]); // 'y'
      final response = await ask.timeout(const Duration(seconds: 2));
      expect(response, PermissionResponse.allowOnce);

      // The input loop's readLine is still pending untouched.
      expect(ed.isEditing, isTrue);
    },
  );

  test(
    'arrows move the selection without deciding; Enter confirms it',
    () async {
      // 02ddd3e made approvals a selectable list: ↑/↓ move the highlight,
      // Enter confirms the highlighted option, y/n/a/d remain shortcuts.
      // An arrow must never decide the ask; Enter now MUST (it is the
      // confirm key), so it is asserted positively here.
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.yes,
      );
      final ed = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      final asker = WorkflowPermissionAsker(
        sink: FakeAgentSink(),
        screen: screen,
        editor: ed,
      );

      final ask = asker.ask(_bashPrompt('cargo test'));
      var decided = false;
      unawaited(ask.whenComplete(() => decided = true));
      await _flush();
      expect(ed.isReadingKey, isTrue);

      // ↑ arrow — not an answer, just redraws the row with the selection.
      io.feedBytes([0x1b, 0x5b, 0x41]);
      await _flush();
      expect(
        decided,
        isFalse,
        reason: 'an arrow key is not an answer — the read stays armed',
      );

      // Enter — the confirm key: it settles the ask with the highlighted
      // option. No arrow was answered with, so the default (allow once).
      io.feedBytes([0x0d]);
      final response = await ask.timeout(const Duration(seconds: 2));
      expect(
        response,
        PermissionResponse.allowOnce,
        reason: 'Enter confirms the highlighted option',
      );
    },
  );

  test(
    'Ctrl+C arms the quit confirm and never settles the approval; Esc denies',
    () async {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        ansi: AnsiCapable.yes,
        layout: ScreenLayout.fromSize(80, 24),
      );
      final editor = LineEditor(screen: screen);
      final asker = WorkflowPermissionAsker(
        sink: FakeAgentSink(),
        screen: screen,
        editor: editor,
      );
      final response = asker.ask(_bashPrompt('pwd'));
      await _flush();
      io.feedBytes([0x03]); // arm only — the approval stays open
      var settled = false;
      response.then((_) => settled = true);
      await _flush();
      expect(settled, isFalse,
          reason: 'the first ctrl+c is the quit flow, not a deny');
      io.feedBytes([0x1b]); // esc denies the prompt
      expect(
        await response.timeout(const Duration(seconds: 2)),
        PermissionResponse.denyOnce,
      );
      expect(editor.isReadingKey, isFalse);
      editor.close();
    },
  );

  test('Esc explicitly denies; n denies; d denies always', () async {
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(80, 24),
      ansi: AnsiCapable.yes,
    );
    final ed = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    final asker = WorkflowPermissionAsker(
      sink: FakeAgentSink(),
      screen: screen,
      editor: ed,
    );

    // Esc — the "get me out" key keeps its meaning.
    final esc = asker.ask(_bashPrompt('rm -rf build'));
    await _flush();
    io.feedBytes([0x1b]);
    await _flush();
    expect(
      await esc.timeout(const Duration(seconds: 2)),
      PermissionResponse.denyOnce,
    );

    // 'n' — an explicit single deny.
    final n = asker.ask(_bashPrompt('ls'));
    await _flush();
    io.feedBytes([0x6e]); // 'n'
    expect(
      await n.timeout(const Duration(seconds: 2)),
      PermissionResponse.denyOnce,
    );

    // 'd' — deny + remember.
    final d = asker.ask(_bashPrompt('ls'));
    await _flush();
    io.feedBytes([0x64]); // 'd'
    expect(
      await d.timeout(const Duration(seconds: 2)),
      PermissionResponse.denyAlways,
    );
  });

  test('approval affordances: spelled-out answers, mode chip, one-shot '
      'ignored-key ack (#51)', () async {
    // (a) The row must say what each key DECIDES — 02ddd3e replaced the old
    // '[y]es [n]o [a]lways allow …' spelling with the selectable option
    // labels; the row still names every decision. (b) The active permission
    // mode must be visible AT THE ASK — the TUI has no footer bar. (c) The
    // FIRST non-answer key that reaches the prompt echoes one dim ack; the
    // second stays silent.
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(120, 24),
      ansi: AnsiCapable.yes,
    );
    final ed = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    final sink = FakeAgentSink();
    final policy = PermissionPolicy()..mode = PermissionMode.allowEdits;
    final asker = WorkflowPermissionAsker(
      sink: sink,
      screen: screen,
      editor: ed,
      policy: policy,
    );

    final ask = asker.ask(_bashPrompt('cargo test'));
    await _flush();
    expect(ed.isReadingKey, isTrue);

    // The asker writes through the sink (showMessage → notice on the fake),
    // never to the screen — assert on what the fake recorded.
    String notices() => sink.notices.map((n) => n.message).join('\n');
    expect(
      notices(),
      contains('approve? [y] allow once [a] allow always [d] deny ‹'),
      reason: '(a) the row names what each key decides',
    );
    expect(
      notices(),
      contains('[mode: allow-edits]'),
      reason: '(b) the header carries the active mode, read from the policy',
    );
    // (b2) "always allow" reads as permanent and global, and is neither: the
    // prompt says what a/d actually covers. A sandbox or outside-sandbox prompt
    // already spells its own scope out, so it carries no note.
    expect(
      notices(),
      contains('this conversation, until tina exits'),
      reason: 'the ordinary prompt states the scope of an "always" answer',
    );

    // (c) first ignored key → one dim ack…
    io.feedBytes([0x71]); // 'q' — not an answer
    await _flush();
    expect(ed.isReadingKey, isTrue, reason: 'the read stays armed');
    expect(
      notices(),
      contains('…'),
      reason: 'the first swallowed key gets a one-shot ack',
    );
    // …the second ignored key gets none.
    io.feedBytes([0x72]); // 'r' — still not an answer
    await _flush();
    final afterSecond = notices().split('…').length - 1;
    expect(
      afterSecond,
      1,
      reason: 'the ack is ONE-SHOT — later ignored keys stay silent',
    );

    io.feedBytes([0x6e]); // 'n' — the answer
    expect(
      await ask.timeout(const Duration(seconds: 2)),
      PermissionResponse.denyOnce,
    );
  });

  test(
    'mode chip tracks the policy live; absent without a policy (#51b)',
    () async {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 24),
        ansi: AnsiCapable.yes,
      );
      final ed = LineEditor(screen: screen, escapeTimeout: Duration.zero);
      final sink = FakeAgentSink();
      final policy = PermissionPolicy()..mode = PermissionMode.ask;
      final asker = WorkflowPermissionAsker(
        sink: sink,
        screen: screen,
        editor: ed,
        policy: policy,
      );

      String notices() => sink.notices.map((n) => n.message).join('\n');
      var ask = asker.ask(_bashPrompt('ls'));
      await _flush();
      expect(notices(), contains('[mode: ask]'));
      io.feedBytes([0x6e]); // 'n'
      await ask.timeout(const Duration(seconds: 2));

      // /permissions flips the mode on the same object — the next ask shows
      // it without rebuilding the asker.
      policy.mode = PermissionMode.readAll;
      ask = asker.ask(_bashPrompt('ls'));
      await _flush();
      expect(notices(), contains('[mode: read-all]'));
      io.feedBytes([0x6e]);
      await ask.timeout(const Duration(seconds: 2));

      // No policy attached → no chip, nothing else changes.
      final io2 = FakeStdio();
      final screen2 = Screen(
        io: io2,
        layout: ScreenLayout.fromSize(120, 24),
        ansi: AnsiCapable.yes,
      );
      final ed2 = LineEditor(screen: screen2, escapeTimeout: Duration.zero);
      final sink2 = FakeAgentSink();
      final asker2 = WorkflowPermissionAsker(
        sink: sink2,
        screen: screen2,
        editor: ed2,
      );
      final ask2 = asker2.ask(_bashPrompt('ls'));
      await _flush();
      expect(
        sink2.notices.map((n) => n.message).join('\n'),
        isNot(contains('[mode:')),
      );
      io2.feedBytes([0x6e]);
      await ask2.timeout(const Duration(seconds: 2));
    },
  );

  test('non-interactive asker attaches a model-facing note to the denial '
      '(#27)', () async {
    // No screen/editor → the auto-deny path. The stderr-only refusal hint was
    // invisible to the model (#27), so the returned response must carry the
    // note that rides on the denied tool result.
    final asker = WorkflowPermissionAsker(sink: FakeAgentSink());

    final res = await asker.ask(_bashPrompt('rm -rf build'));

    expect(res.decision, PermissionDecision.deny);
    expect(res.note, contains('Non-interactive run: permission asks'));
    expect(res.note, contains('rephrasing will not change this'));
  });
}
