import 'dart:async';

import 'package:tina/pipeline/workflow_permission_asker.dart';
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
    'non-answer keys (arrows, Enter, stray chars) never decide the approval',
    () async {
      // The reported bug: pressing ↑ while the prompt was open fell into the
      // default-deny and silently rejected the action. Only y/n/a/d (and Esc,
      // explicitly) are answers; every other key must leave the read armed.
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

      // ↑ arrow — not a CharInput, must not decide anything.
      io.feedBytes([0x1b, 0x5b, 0x41]);
      await _flush();
      expect(
        decided,
        isFalse,
        reason: 'an arrow key is not an answer — the read stays armed',
      );

      // Enter — not an answer either.
      io.feedBytes([0x0d]);
      await _flush();
      expect(decided, isFalse, reason: 'Enter is not an answer');

      // A stray printable character — ignored.
      io.feedBytes([0x71]); // 'q'
      await _flush();
      expect(decided, isFalse, reason: '"q" is not an answer');

      // The actual answer decides.
      io.feedBytes([0x79]); // 'y'
      final response = await ask.timeout(const Duration(seconds: 2));
      expect(response, PermissionResponse.allowOnce);
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
    // (a) The row must say what each key DECIDES — the old
    // '[y/n/a/d] (a/d remember …)' said both were remembered, never that
    // 'a' allows and 'd' denies. (b) The active permission mode must be
    // visible AT THE ASK — the TUI has no footer bar. (c) The FIRST
    // non-answer key that reaches the prompt echoes one dim ack; the second
    // stays silent.
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
      contains(
        'approve? [y]es [n]o [a]lways allow [d]eny always '
        '(a/d: "cargo test") ›',
      ),
      reason: '(a) the four answers are spelled out with their decisions',
    );
    expect(
      notices(),
      contains('[mode: allow-edits]'),
      reason: '(b) the header carries the active mode, read from the policy',
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
