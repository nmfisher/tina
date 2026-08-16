import 'dart:async';

import 'package:tina/pipeline/workflow_permission_asker.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_stdio.dart';

LineEditor _editor(FakeStdio io) {
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.yes,
  );
  return LineEditor(
    screen: screen,
    escapeTimeout: Duration.zero,
  );
}

PermissionPrompt _bashPrompt(String command) =>
    PermissionPrompt('bash', {'command': command});

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('askPermission readKey waits while the user is typing a prompt', () async {
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
        sink: sink, screen: screen, editor: ed);

    // The user is typing a prompt (readLine pending) when the approval lands.
    final line = ed.readLine('> ');
    await _flush();
    final ask = asker.ask(_bashPrompt('ls -la'));
    await _flush();
    io.feedBytes([0x61]); // 'a'
    await _flush();

    // The approval's readKey is not armed yet — it must wait for the submit.
    expect(ed.isReadingKey, isFalse,
        reason: 'approval must not arm while the user is typing');

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
  });
}
