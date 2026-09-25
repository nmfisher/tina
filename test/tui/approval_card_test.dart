import 'package:test/test.dart';
import 'package:tina/frontend/renderers.dart';
import 'package:tina/tui/approval_card.dart';
import 'package:tina/tui/permission_approval.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_stdio.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

String render(ApprovalCard card, {int width = 100}) => const ApprovalRenderer()
    .render(card, RenderContext(width: width, theme: const Theme.defaults()))
    .map((line) => line.runs.map((run) => run.text).join())
    .join('\n');

class CustomApproval extends Renderer<ApprovalCard> {
  @override
  List<RenderLine> render(ApprovalCard value, RenderContext context) => [
    const RenderLine(runs: [RenderRun('Custom tool preview', null)]),
  ];
}

void main() {
  final execution = ExecutionRequest(
    executable: '/bin/sh',
    arguments: ['-c', 'printf "%s\\n" "a b"\ndart test'],
    workingDirectory: '/project/packages/console',
    environment: {'PRIVATE_INHERITED': 'do-not-display'},
    environmentOverrides: {'MODE': 'test'},
    writablePaths: ['/cache'],
    timeoutSeconds: 120,
    shell: true,
  );

  test(
    'shell preview uses the prepared invocation, with details on demand',
    () {
      final prompt = PermissionPrompt('bash', {
        'command': 'different command',
      }, execution: execution);
      final summary = render(ApprovalCard(prompt: prompt));
      expect(summary, contains(execution.arguments.last));
      expect(summary, contains('Directory: /project/packages/console'));
      expect(summary, contains('1 overrides (Tab details)'));
      expect(summary, isNot(contains('Executable:')));
      final details = render(ApprovalCard(prompt: prompt, details: true));
      expect(details, contains('Executable: /bin/sh'));
      expect(details, contains('Environment override: MODE=test'));
      expect(details, contains('Timeout: 120s'));
      expect(details, isNot(contains('do-not-display')));
    },
  );

  test('exec preview is one line: executable then its arguments', () {
    final prompt = PermissionPrompt('exec', const {
      'executable': '/bin/sh',
      'args': ['-lc', 'cargo build --release; echo done'],
      'cwd': '/project',
    });
    final summary = render(ApprovalCard(prompt: prompt));
    expect(summary, contains("/bin/sh -lc 'cargo build --release; echo done'"));
    expect(summary, isNot(contains('Argument ')));
    // Whitespace-safe argv (no metacharacters) needs no quoting at all.
    final plain = render(
      const ApprovalCard(
        prompt: PermissionPrompt('exec', {
          'executable': 'dart',
          'args': ['test', '-r', 'expanded'],
        }),
      ),
    );
    expect(plain, contains('dart test -r expanded'));
    expect(plain, isNot(contains("'")));
  });

  test('formatArgv quotes only the words that need it', () {
    expect(formatArgv('ls', ['-la', '/tmp']), 'ls -la /tmp');
    // An empty argument would vanish unquoted.
    expect(formatArgv('touch', ['']), "touch ''");
    // An embedded quote closes, escapes, reopens.
    expect(formatArgv('echo', ["it's here"]), r"echo 'it'\''s here'");
    // Whitespace would split.
    expect(formatArgv('printf', ['a b']), "printf 'a b'");
    // Control bytes stay literal; the renderer escapes them for display.
    expect(formatArgv('printf', ['a\tb']), "printf 'a\tb'");
  });

  test('titles distinguish a shell line from a direct program run', () {
    expect(
      const ApprovalCard(
        prompt: PermissionPrompt('bash', {'command': 'ls -la'}),
      ).title,
      'Run shell command',
    );
    expect(
      const ApprovalCard(
        prompt: PermissionPrompt('exec', {'executable': 'ls'}),
      ).title,
      'Run program',
    );
    // Anything else keeps its raw tool name — the header never invents a
    // generic label that could hide which tool is being approved.
    expect(
      const ApprovalCard(prompt: PermissionPrompt('custom', {})).title,
      'custom',
    );
  });

  test('wrapping preserves spaces, Unicode and literal shell operators', () {
    const command = 'printf "漢字 😀"  && echo "a b"';
    final rows = approvalWrap(command, 12);
    expect(rows.join(), command);
    expect(rows.every((row) => plainWidth(row) <= 12), isTrue);
    expect(approvalWrap('echo \x1b[2J', 80).single, r'echo \x1b[2J');
  });

  test(
    'unknown tools retain structured arguments; edits retain both sides',
    () {
      expect(
        render(
          const ApprovalCard(
            prompt: PermissionPrompt('custom', {
              'path': '/project/file',
              'options': {'recursive': true},
            }),
          ),
        ),
        contains('options: {"recursive":true}'),
      );
      final diff = render(
        const ApprovalCard(
          prompt: PermissionPrompt('edit', {'filePath': '/project/a.dart'}),
          preview: [
            PreviewHeader('/project/a.dart'),
            PreviewRemoved('old'),
            PreviewAdded('new'),
          ],
        ),
      );
      expect(diff, contains('- old\n+ new'));
    },
  );

  for (final width in [48, 100]) {
    test(
      'long preview scrolls in place with choices visible at width $width',
      () async {
        final io = FakeStdio();
        final screen = Screen(
          io: io,
          layout: ScreenLayout.fromSize(width, 24),
          ansi: AnsiCapable.yes,
        );
        final editor = LineEditor(screen: screen);
        addTearDown(editor.close);
        final history = StringBuffer();
        final command = List.generate(70, (i) => 'echo line_$i').join('\n');
        final pending = runPermissionApproval(
          screen: screen,
          editor: editor,
          prompt: PermissionPrompt('bash', {'command': command}),
          write: history.write,
        );
        await flush();
        String visible() {
          final terminal = VirtualTerminal(width: width, height: 24)
            ..feed(io.written.toString());
          return List.generate(24, terminal.rowText).join('\n');
        }

        expect(visible(), contains('echo line_0'));
        expect(visible(), contains('[y] allow once'));
        expect(visible(), contains('Preview '));
        for (var i = 0; i < 4; i++) {
          editor.inject(ArrowKey(ArrowDirection.pageDown));
          await flush();
        }
        expect(visible(), isNot(contains('echo line_0')));
        expect(visible(), contains('[y] allow once'));
        expect(history.isEmpty, isTrue);
        for (var i = 0; i < 20; i++) {
          editor.inject(ScrollEvent(up: i.isEven));
          await flush();
        }
        expect(
          history.isEmpty,
          isTrue,
          reason: 'scrolling never appends a card',
        );
        editor.inject(ArrowKey(ArrowDirection.down));
        await flush();
        editor.inject(ControlKey(ControlCode.enter));
        expect((await pending).decision, PermissionDecision.deny);
        // One settled record, one line, and it names the call itself: a denial
        // never reaches the tool row that would otherwise print it. The
        // preview card was for deciding, not for replaying into history.
        final settled = history.toString();
        expect(
          settled.split('\n').where((line) => line.trim().isNotEmpty),
          hasLength(1),
        );
        expect(settled, contains('bash: '));
        expect(settled, contains('echo line_0'));
        expect(settled, contains('deny once'));
        expect(settled, isNot(contains('┌')));
        expect(settled, isNot(contains('Directory: ')));
      },
    );
  }

  test('an approved call hands its one-line record to onSettled', () async {
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final editor = LineEditor(screen: screen);
    addTearDown(editor.close);
    final history = StringBuffer();
    final settled = StringBuffer();
    final pending = runPermissionApproval(
      screen: screen,
      editor: editor,
      prompt: PermissionPrompt('bash', {'command': 'git status'}),
      write: history.write,
      onSettled: settled.write,
    );
    await flush();
    editor.inject(ControlKey(ControlCode.enter)); // first choice: allow once
    expect((await pending).decision, PermissionDecision.allow);
    // The record is the decision only — the call itself is the tool row's
    // job, and a row that does not exist yet (this runs before the tool
    // starts) is why the record is handed over rather than written.
    expect(settled.toString(), '  Run shell command · allow once\n');
    expect(history.isEmpty, isTrue);
  });

  test(
    'Tab reveals details without answering; double Escape cancels',
    () async {
      final io = FakeStdio();
      final screen = Screen(io: io, layout: ScreenLayout.fromSize(120, 30));
      final editor = LineEditor(screen: screen);
      addTearDown(editor.close);
      final pending = runPermissionApproval(
        screen: screen,
        editor: editor,
        prompt: PermissionPrompt('bash', {
          'command': 'dart test',
        }, execution: execution),
        write: (_) {},
      );
      await flush();
      editor.inject(ControlKey(ControlCode.tab));
      await flush();
      expect(
        io.written.toString(),
        contains('Environment override: MODE=test'),
      );
      expect(editor.isReadingKey, isTrue);
      editor.inject(EscapeKey());
      editor.inject(EscapeKey());
      expect((await pending).decision, PermissionDecision.deny);
      expect(editor.isReadingKey, isFalse);
    },
  );

  test(
    'approval content uses the plugin renderer; choices still govern responses',
    () async {
      final scope = PluginScope('approval');
      addTearDown(scope.dispose);
      scope.registerContribution(
        pluginId: 'test',
        id: 'approval',
        contribution: CustomApproval(),
      );
      final io = FakeStdio();
      final screen = Screen(io: io, layout: ScreenLayout.fromSize(100, 24));
      final editor = LineEditor(screen: screen);
      addTearDown(editor.close);
      final pending = runPermissionApproval(
        screen: screen,
        editor: editor,
        prompt: const PermissionPrompt('bash', {'command': 'dart test'}),
        renderers: Renderers(scope),
        write: (_) {},
      );
      await flush();
      expect(io.written.toString(), contains('Custom tool preview'));
      editor.inject(CharInput('a'));
      final answer = await pending;
      expect(answer.decision, PermissionDecision.allow);
      expect(answer.scope, GrantScope.conversation);
      expect(answer.remember, isTrue);
    },
  );
}
