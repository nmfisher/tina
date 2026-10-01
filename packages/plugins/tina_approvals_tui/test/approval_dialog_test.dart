import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

/// Headless: the dialog driven from scripted keys — no terminal.
void main() {
  String text(RenderLine row) => row.runs.map((run) => run.text).join();

  test('permission cards render quoted commands and colored edit previews', () {
    final command = ApprovalDialog(null,
        ask: const ApprovalAskContext('run command', 'git', 'ask mode',
            details: {
              'cwd': '/project',
              'tool': {
                'name': 'exec',
                'input': {
                  'program': 'git',
                  'args': ['commit', '-m', 'two words']
                }
              }
            }));
    final output = command.rows().map(text).join('\n');
    expect(output, contains('Run program'));
    expect(output, contains("git commit -m 'two words'"));
    expect(output, contains('Directory: /project'));
    final edit = ApprovalDialog(const ToolUse(id: 'edit', name: 'edit', input: {
      'filePath': 'a.txt',
      'oldString': 'before',
      'newString': 'after'
    }));
    final runs = edit.rows().expand((r) => r.runs).toList();
    expect(runs.singleWhere((r) => r.text.contains('- before')).code,
        Theme.defaults().chat.red);
    expect(runs.singleWhere((r) => r.text.contains('+ after')).code,
        Theme.defaults().chat.green);
  });

  test('plugin-owned action descriptions work for an unfamiliar tool', () {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext(
            'deploy', 'preview.example', 'Publish this preview?',
            details: {
              'description': const ToolDescription(
                  title: 'Publish preview',
                  target: 'preview.example',
                  fields: {'Destination': 'preview.example'}).toJson(),
              'tool': {
                'name': 'acme_deploy',
                'input': {'site_id': 'internal-id', 'api_token': 'secret-value'}
              },
            }));
    var shown = dialog.rows().map(text).join('\n');
    expect(shown, contains('Publish preview'));
    expect(shown, contains('Destination: preview.example'));
    expect(shown, isNot(contains('site_id')));
    dialog.handleKey(ApprovalKey.details);
    shown = dialog.rows().map(text).join('\n');
    expect(shown, contains('site_id'));
    expect(shown, contains('[redacted]'));
    expect(shown, isNot(contains('secret-value')));
  });

  test('scope wording matches exact file and command grants', () {
    for (final scope in ['file', 'command']) {
      final dialog = ApprovalDialog(null,
          ask: ApprovalAskContext('request', '/actual/target', 'needs approval',
              details: {'permission_scope': scope}));
      expect(dialog.rows(width: 100).map(text).join('\n'),
          contains('[a] allow this $scope for this session'));
      dialog.handleKey(ApprovalKey.down);
      dialog.handleKey(ApprovalKey.down);
      expect(dialog.current.decision, ApprovalDecision.allowAlways);
    }
  });

  test('classifier failure details identify its model and response status', () {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext('run command', 'sed -n 1,10p file',
            'classifier returned no verdict',
            details: {
              'mode': 'auto',
              'auto_approval_classifier': {
                'model': 'provider/model',
                'attempts': 2,
                'answer_characters': 0,
                'reasoning_characters': 512,
                'stop_reason': 'stop'
              },
            }));
    dialog.handleKey(ApprovalKey.details);
    final shown = dialog.rows(width: 100, height: 30).map(text).join('\n');
    expect(shown, contains('Approval classifier: provider/model'));
    expect(shown, contains('Classifier attempts: 2'));
    expect(shown, contains('Classifier answer: 0 characters'));
    expect(shown, contains('Classifier completion: stop'));
  });

  test('human-only confirmations display the actual command and directory', () {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext('Allow network access?', 'git push',
            'This command needs network access.',
            confirmation: true,
            details: {
              'description': const ToolDescription(
                  title: 'Push Git changes',
                  target: 'git push origin work',
                  fields: {'Command': 'git push origin work'}).toJson(),
              'cwd': '/project',
            }));
    final shown = dialog.rows(width: 100).map(text).join('\n');
    expect(shown, contains('Command: git push origin work'));
    expect(shown, contains('Directory: /project'));
    expect(shown, contains('❯ [y] Yes'));
    expect(shown, isNot(contains('[a]')));
  });

  test(
      'automatic denial reason is visible before command details in a short terminal',
      () {
    const reason = 'Project data could be exposed.';
    const requestReason =
        'Auto approval: classifier recommends denial. This command needs network access.';
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext('run command', 'git push', requestReason,
            details: {
              'cwd': '/a/long/workspace/path/that/should/not/hide/the/denial',
              'auto_approval_denial_reason': reason,
              'tool': {
                'name': 'exec',
                'input': {
                  'program': 'git',
                  'args': ['push', 'origin', 'work']
                }
              }
            }));
    var rows = dialog.rows(width: 78, height: 7).map(text).toList();
    expect(rows, hasLength(7));
    expect(rows[1], '│ Why: $reason');
    expect(rows[rows.length - 3], '❯ [y] allow once');
    expect(rows[rows.length - 2], '  [n] deny');
    expect(rows.last, '  [a] allow this command for this session');
    final pages = <String>[];
    for (var i = 0; i < 15; i++) {
      pages.addAll(dialog.rows(width: 78, height: 7).map(text));
      dialog.handleKey(ApprovalKey.pageDown);
    }
    expect(pages.join('\n'), contains('git push origin work'));
    dialog.handleKey(ApprovalKey.details);
    rows = dialog.rows(width: 120, height: 30).map(text).toList();
    expect(rows.join('\n'), contains('Why: $requestReason'));
    for (var height = 1; height <= 7; height++) {
      final compact =
          ApprovalDialog(null, ask: dialog.ask).rows(width: 30, height: height);
      expect(compact.length, lessThanOrEqualTo(height));
      expect(compact.map(text).join('\n'), contains('❯ [y]'));
    }
  });

  test('permission scope text is supplied by plugins, including network grants',
      () async {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext('run command', 'git fetch origin',
            'Network access: fetch dependencies. Filesystem confinement remains active.',
            details: {
              'cwd': '/project',
              'permission_scope': 'command',
              'permission_scope_label': 'this command with network access',
              'permission_scope_description':
                  'This exact command and its network access only; other commands still ask.',
              'description': const ToolDescription(
                  title: 'Fetch Git changes with network access',
                  target: 'git fetch origin',
                  fields: {'Command': 'git fetch origin'}).toJson(),
            }));
    final shown = dialog.rows(width: 120).map(text).join('\n');
    expect(shown, contains('Fetch Git changes with network access'));
    expect(shown, contains('Directory: /project'));
    expect(shown, contains('git fetch origin'));
    expect(shown, contains('[y] allow once'));
    expect(shown, contains('[n] deny'));
    expect(
        shown,
        contains(
            '[a] allow this command with network access for this session'));
    expect(shown, contains('other commands still ask'));
    expect(shown, isNot(contains('[y] Yes')));
    expect(
        (await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.always])))
            .decision,
        ApprovalDecision.allowAlways);
  });

  test('short terminal cards reserve space for context above the input choices',
      () {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext(
            'write', '/outside/notes.txt', 'outside the project'));
    final rows = dialog.rows(width: 80, height: 7).map(text).toList();
    expect(rows.join('\n'), contains('/outside/notes.txt'));
    expect(rows[rows.length - 3], '❯ [y] allow once');
    expect(rows[rows.length - 2], '  [n] deny');
    expect(rows.last, '  [a] allow this file for this session');
  });

  test('permission and Yes/No answers use the same vertical selector', () {
    for (final confirmation in [false, true]) {
      final dialog = ApprovalDialog(null,
          ask: ApprovalAskContext(
              'Continue?', 'target.txt', 'Review this action',
              confirmation: confirmation));
      final count = confirmation ? 2 : 3;
      for (final width in [40, 80, 160]) {
        final rows = dialog.rows(width: width, height: 12);
        final answers = rows
            .where((r) => RegExp(r'^.[ ]\[[yna]\]').hasMatch(text(r)))
            .toList();
        expect(answers, hasLength(count));
        expect(
            answers.map(text).where((s) => s.startsWith('❯ ')), hasLength(1));
        expect(answers.first.runs.single.code, Theme.defaults().dialog.confirm);
        expect(rows.map(text).join(), isNot(contains('[x]')));
      }
      dialog.handleKey(ApprovalKey.down);
      final selected =
          dialog.rows().singleWhere((r) => text(r).startsWith('❯ '));
      expect(text(selected), confirmation ? '❯ [n] No' : '❯ [n] deny');
      expect(selected.runs.single.code, Theme.defaults().dialog.confirm);
    }
  });
  test('command is readable and preview paging keeps the selected answer', () {
    final dialog = ApprovalDialog(ToolUse(id: 'long', name: 'bash', input: {
      'command': List.generate(30, (i) => 'echo line_$i').join('\n')
    }));
    var rows = dialog.rows(width: 80, height: 12);
    expect(
        rows
            .expand((r) => r.runs)
            .singleWhere((r) => r.text.contains('echo line_0'))
            .code,
        isNull);
    expect(rows.map(text).join('\n'), contains('Preview'));
    dialog.handleKey(ApprovalKey.down);
    final decision = dialog.current.decision;
    final seen = <String>[];
    for (var i = 0; i < 20; i++) {
      rows = dialog.rows(width: 80, height: 12);
      seen.addAll(rows.map(text));
      expect(rows.map(text).join('\n'), contains('❯ [n] deny'));
      dialog.handleKey(ApprovalKey.pageDown);
      expect(dialog.current.decision, decision);
    }
    expect(seen.join('\n'), contains('echo line_29'));
    dialog.handleKey(ApprovalKey.pageUp);
    expect(dialog.rows(width: 80, height: 12).map(text).join('\n'),
        isNot(contains('echo line_29')));
  });

  test('edit context is unchanged and diff colors survive Tab details', () {
    final dialog =
        ApprovalDialog(const ToolUse(id: 'edit', name: 'edit', input: {
      'path': 'file.dart',
      'oldString': 'header\nbefore\nfooter',
      'newString': 'header\nafter\nfooter',
    }));
    for (var i = 0; i < 2; i++) {
      final runs = dialog.rows().expand((r) => r.runs).toList();
      expect(runs.singleWhere((r) => r.text.contains('- before')).code,
          Theme.defaults().chat.red);
      expect(runs.singleWhere((r) => r.text.contains('+ after')).code,
          Theme.defaults().chat.green);
      expect(runs.singleWhere((r) => r.text.contains('  header')).code,
          Theme.defaults().chat.dim);
      expect(runs.any((r) => r.text.contains('- header')), isFalse);
      dialog.handleKey(ApprovalKey.details);
    }
  });

  test('permission shortcuts and tiny layouts retain a visible selection',
      () async {
    for (final entry in {
      ApprovalKey.allow: ApprovalDecision.allow,
      ApprovalKey.deny: ApprovalDecision.deny,
      ApprovalKey.always: ApprovalDecision.allowAlways,
    }.entries) {
      final dialog = ApprovalDialog(const ToolUse(
          id: 'x', name: 'bash', input: {'command': 'echo hello'}));
      expect(
          (await dialog.awaitDecision(ScriptedKeySource([entry.key]))).decision,
          entry.value);
      for (var height = 1; height <= 12; height++) {
        final rows = dialog.rows(width: 30, height: height);
        expect(rows.length, lessThanOrEqualTo(height));
        expect(rows.map(text).join('\n'), contains('❯ [y]'));
      }
    }
  });
  test('tool previews escape terminal control sequences', () {
    final dialog = ApprovalDialog(const ToolUse(
        id: 'x', name: 'bash', input: {'command': 'echo \x1b[2J'}));
    final output = dialog.rows().map(text).join('\n');
    expect(output, isNot(contains('\x1b')));
    expect(output, contains(r'\x1b[2J'));
  });
  test('confirmation wraps its question and offers only Yes/No', () async {
    const question =
        'Your message contains grok, this is a no-no. Are you sure you want to proceed?';
    ApprovalDialog dialog() => ApprovalDialog(null,
        ask: const ApprovalAskContext('Send message?', 'user input', question,
            confirmation: true));
    final rows = dialog().rows(width: 80, height: 10);
    final text = rows.map((r) => r.runs.map((s) => s.text).join()).join('\n');
    expect(text, contains(question));
    expect(text, contains('❯ [y] Yes'));
    expect(text, contains('  [n] No'));
    expect(text, isNot(contains('[x]')));
    expect(text, isNot(contains('always')));
    expect(
        (await dialog().awaitDecision(ScriptedKeySource([ApprovalKey.confirm])))
            .decision,
        ApprovalDecision.allow);
    expect(
        (await dialog().awaitDecision(
                ScriptedKeySource([ApprovalKey.down, ApprovalKey.confirm])))
            .decision,
        ApprovalDecision.deny);
    expect(
        (await dialog().awaitDecision(ScriptedKeySource([ApprovalKey.cancel])))
            .decision,
        ApprovalDecision.deny);
    final small = dialog().rows(width: 40, height: 5);
    expect(small.length, lessThanOrEqualTo(5));
    expect(small.map((r) => r.runs.map((s) => s.text).join()).join('\n'),
        contains('[n] No'));
  });
  final call = const ToolUse(
    id: 'c1',
    name: 'bash',
    input: {'command': 'rm -rf build/'},
  );

  test('the decision comes from scripted keys: enter on default allows',
      () async {
    final outcome = await ApprovalDialog(call)
        .awaitDecision(ScriptedKeySource([ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allow);
    expect(outcome.isCancellation, isFalse);
  });

  test('down selects deny; enter confirms deny', () async {
    final outcome = await ApprovalDialog(call).awaitDecision(
      ScriptedKeySource([ApprovalKey.down, ApprovalKey.confirm]),
    );
    expect(outcome.decision, ApprovalDecision.deny);
  });

  test('up and down cannot leave the choice list', () async {
    final outcome = await ApprovalDialog(call).awaitDecision(
      ScriptedKeySource([ApprovalKey.up, ApprovalKey.up, ApprovalKey.confirm]),
    );
    expect(outcome.decision, ApprovalDecision.allow);
  });

  test('escape cancels: a denial, marked cancelled', () async {
    final outcome = await ApprovalDialog(call)
        .awaitDecision(ScriptedKeySource([ApprovalKey.cancel]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.isCancellation, isTrue);
  });

  test('a closed key source denies without throwing', () async {
    final outcome =
        await ApprovalDialog(call).awaitDecision(ScriptedKeySource([]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.isCancellation, isTrue);
  });

  test('a call with a parse error is never offered "allow always"', () async {
    final broken = const ToolUse(
      id: 'c2',
      name: 'bash',
      input: {},
      argumentsParseError: 'bad JSON',
    );
    final dialog = ApprovalDialog(broken);
    // First choice is now plain allow.
    final outcome =
        await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allow);
  });

  test('rows show the call, its args, and one marker per choice', () {
    final rows = ApprovalDialog(call).rows(width: 80);
    final texts = rows.map(text).toList();
    expect(texts.first, '┌ Run shell command · awaiting approval');
    expect(texts.any((t) => t.contains('rm -rf build/')), isTrue);
    expect(texts.where((t) => t.startsWith('❯ [')), hasLength(1));
    expect(texts.join(), contains('[n] deny'));
    expect(texts.join(), contains('[a] allow this command'));
    expect(texts.any((t) => t.contains('allow this command')), isTrue);
    expect(texts.join(), contains('Esc deny'));
    expect(texts.last, contains('[a] allow this command'));
  });

  test('selected choice is highlighted with the dialog style', () {
    final dialog = ApprovalDialog(call);
    final rows = dialog.rows();
    final selected =
        rows.expand((r) => r.runs).firstWhere((r) => r.text.startsWith('❯ ['));
    expect(selected.code, Theme.defaults().dialog.confirm);
    dialog.handleKey(ApprovalKey.down);
    final moved = dialog.rows();
    final highlighted = moved
        .expand((r) => r.runs)
        .where((r) => r.text.startsWith('❯ ['))
        .toList();
    expect(highlighted, hasLength(1));
    expect(highlighted.single.text, contains('deny'));
    expect(highlighted.single.text, isNot(contains('allow this command')));
    expect(highlighted.single.code, Theme.defaults().dialog.confirm);
  });

  test('long arguments clip to the width', () {
    final wide = ToolUse(
      id: 'c3',
      name: 'write',
      input: {'path': 'a.txt', 'content': 'y' * 200},
    );
    final rows = ApprovalDialog(wide).rows(width: 40);
    for (final row in rows) {
      expect(visibleWidth(text(row)), lessThanOrEqualTo(40));
    }
  });

  test('small layouts keep selection inside the modal including after resize',
      () {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext(
            'write', '/${'長いパス/' * 25}target.txt', 'outside the project'));
    for (final size in [(80, 10), (40, 8), (20, 6), (120, 30)]) {
      final layout = ScreenLayout.fromSize(size.$1, size.$2, split: false);
      final area = dialogArea(layout);
      for (var i = 0; i < 3; i++) {
        final rows = dialog.rows(width: area.width, height: area.height);
        final lines = rows.map(text).toList();
        expect(rows.length, lessThanOrEqualTo(area.height));
        expect(
            rows
                .expand((row) => row.runs)
                .where((run) => run.text.startsWith('❯ [')),
            hasLength(1));
        for (final line in lines)
          expect(visibleWidth(line), lessThanOrEqualTo(area.width));
        expect(lines.join(), contains('❯ ['));
        dialog.handleKey(ApprovalKey.down);
      }
      expect(dialog.current.decision, ApprovalDecision.allowAlways);
    }
  });

  test('a one-row prompt keeps the selected answer visible', () {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext('Confirm', '', 'Question',
            confirmation: true));
    dialog.handleKey(ApprovalKey.down);
    final rows = dialog.rows(width: 14, height: 1);
    expect(rows, hasLength(1));
    expect(text(rows.single), '❯ [n] No (2/2)');
  });

  test('details scroll to the complete path; enter returns without approving',
      () async {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext(
            'write', '/${'long-directory/' * 20}END_OF_PATH', 'reason'));
    dialog.handleKey(ApprovalKey.details);
    final rendered = <String>[];
    for (var i = 0; i < 100; i++) {
      rendered.addAll(
          dialog.rows(width: 28, height: 4).map((r) => r.runs.single.text));
      dialog.handleKey(ApprovalKey.down);
    }
    expect(rendered.join(), contains('END_OF_PATH'));
    final outcome = await dialog.awaitDecision(ScriptedKeySource([
      ApprovalKey.confirm, // leave details
      ApprovalKey.down, ApprovalKey.confirm,
    ]));
    expect(outcome.decision, ApprovalDecision.deny);
  });
}
