import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';

class Requests implements ApprovalRequester {
  final requests = <Map<String, Object?>>[];
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {}}) async {
    requests
        .add({'operation': operation, 'target': target, 'details': details});
    return ApprovalDecision.deny;
  }
}

void main() {
  test('argv display preserves spaces, quotes and literal shell syntax', () {
    expect(
        commandText('git',
            ['commit', '-m', "it's two words", r'$(echo secret)', '*.dart']),
        r"git commit -m 'it'\''s two words' '$(echo secret)' '*.dart'");
    final description = describeExec({
      'program': '/usr/bin/git',
      'args': ['push', '-u', 'origin', 'topic']
    });
    expect(description.title, 'Push Git changes');
    expect(description.fields['Command'], '/usr/bin/git push -u origin topic');
    expect(
        describeExec({
          'program': 'git',
          'args': ['-C', '/other', 'push']
        }).title,
        'Run git');
    expect(
        describeExec({
          'program': 'git',
          'args': ['checkout', '--', 'file']
        }).title,
        'Run Git checkout');
  });

  test('approval metadata carries the resolved target and command grant scope',
      () async {
    final root = Directory.systemTemp
        .createTempSync('tool-description-')
        .resolveSymbolicLinksSync();
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final workspace = Directory('$root/project')..createSync();
    final requests = Requests();
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('$root/tina'),
        osSandbox: false);
    tools.modePolicy.approvals = requests;
    final loop = AgentLoop(
        provider: ScriptedProvider([
          scriptedReply('', calls: [
            ToolUseBlock(id: 'outside', name: 'write', input: {
              'filePath': '../outside',
              'content': 'must not be written',
            })
          ]),
          scriptedReply('denied'),
          scriptedReply('', calls: [
            const ToolUseBlock(id: 'command', name: 'exec', input: {
              'program': 'git',
              'args': ['push', '-u', 'origin', 'topic'],
            })
          ]),
          scriptedReply('denied'),
        ]),
        plugins: [tools]);
    tools.mountOn(loop);
    addTearDown(tools.closeSession);
    await loop.runTurn(const Input('write outside', id: 'write'));
    final file = requests.requests.single['details'] as Map;
    final description = ToolDescription.fromJson(file['description'])!;
    expect(description.title, 'Write file');
    expect(description.target, '$root/outside');
    expect(file['permission_scope'], 'file');
    expect(File('$root/outside').existsSync(), isFalse);
    await loop.runTurn(const Input('push', id: 'push'));
    final command = requests.requests.last['details'] as Map;
    expect(command['permission_scope'], 'command');
    expect(ToolDescription.fromJson(command['description'])!.title,
        'Push Git changes');
    expect(command['cwd'], workspace.path);
  });
}
