import 'dart:async';
import 'dart:collection';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';

void main() {
  group('Agent permission gating', () {
    test('deny short-circuits — tool.execute is not called', () async {
      final fakeWrite = _RecordingTool('write');
      final tools = ToolRegistry([fakeWrite]);
      final provider = _ScriptedProvider([
        // turn 1: model asks to write
        [
          ToolUseBlock(id: 'u1', name: 'write', input: const {
            'filePath': '/tmp/out.txt',
            'content': 'hi',
          }),
        ],
        // turn 2: model wraps up after seeing the tool_result
        const [TextBlock('done.')],
      ]);
      final policy = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'write',
            pattern: '/tmp/**',
            decision: PermissionDecision.deny),
      ]);
      final asker = _RecordingAsker([]);

      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: policy,
        asker: asker.ask,
        system: 'sys',
      );
      final history = <Message>[];
      await agent.run(
        history: history,
        userInput: 'write /tmp/out.txt',
      );

      expect(fakeWrite.calls, isEmpty,
          reason: 'deny should not reach execute');
      expect(asker.prompts, isEmpty,
          reason: 'static deny should not ask the user');

      final lastUser =
          history.lastWhere((m) => m.role == Role.user).content.single;
      lastUser as ToolResultBlock;
      expect(lastUser.isError, isTrue);
      expect(lastUser.content, contains('Denied by permission policy'));
    });

    test('ask -> allow-always remembers a broader pattern', () async {
      final fakeWrite = _RecordingTool('write');
      final tools = ToolRegistry([fakeWrite]);
      final provider = _ScriptedProvider([
        // Two writes to the same dir in one assistant turn.
        [
          ToolUseBlock(id: 'u1', name: 'write', input: const {
            'filePath': '/tmp/foo.txt',
            'content': 'a',
          }),
          ToolUseBlock(id: 'u2', name: 'write', input: const {
            'filePath': '/tmp/bar.txt',
            'content': 'b',
          }),
        ],
        const [TextBlock('done.')],
      ]);
      final policy = PermissionPolicy();
      final asker =
          _RecordingAsker([PermissionResponse.allowAlways]);

      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: policy,
        asker: asker.ask,
        system: 'sys',
      );
      await agent.run(
        history: <Message>[],
        userInput: 'write two files in /tmp',
      );

      expect(asker.prompts.length, 1,
          reason: 'second write should use the session rule');
      expect(fakeWrite.calls.length, 2);
      expect(policy.sessionRules.single.pattern, '/tmp/*');
      expect(
          policy.sessionRules.single.decision, PermissionDecision.allow);
    });

    test('ask -> deny once does not remember', () async {
      final fakeWrite = _RecordingTool('write');
      final tools = ToolRegistry([fakeWrite]);
      final provider = _ScriptedProvider([
        [
          ToolUseBlock(id: 'u1', name: 'write', input: const {
            'filePath': '/tmp/foo.txt',
            'content': 'a',
          }),
          ToolUseBlock(id: 'u2', name: 'write', input: const {
            'filePath': '/tmp/bar.txt',
            'content': 'b',
          }),
        ],
        const [TextBlock('done.')],
      ]);
      final policy = PermissionPolicy();
      final asker = _RecordingAsker([
        PermissionResponse.denyOnce,
        PermissionResponse.allowOnce,
      ]);

      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: policy,
        asker: asker.ask,
        system: 'sys',
      );
      await agent.run(
        history: <Message>[],
        userInput: 'write two files',
      );

      expect(asker.prompts.length, 2,
          reason: 'deny-once must not add a session rule');
      expect(fakeWrite.calls.length, 1,
          reason: 'first call denied, second allowed');
      expect(policy.sessionRules, isEmpty);
    });

    test('--yolo defaults flow through buildPolicy', () async {
      // Simulated via builtin defaults map: all four set to allow.
      final policy = PermissionPolicy(defaults: const {
        'read': PermissionDecision.allow,
        'write': PermissionDecision.allow,
        'edit': PermissionDecision.allow,
        'bash': PermissionDecision.allow,
      });
      final fakeBash = _RecordingTool('bash');
      final tools = ToolRegistry([fakeBash]);
      final provider = _ScriptedProvider([
        [
          ToolUseBlock(id: 'u1', name: 'bash', input: const {
            'command': 'rm -rf /tmp/scratch',
          }),
        ],
        const [TextBlock('ok.')],
      ]);
      final asker =
          _RecordingAsker([]); // should never be called under yolo

      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: policy,
        asker: asker.ask,
        system: 'sys',
      );
      await agent.run(
        history: <Message>[],
        userInput: 'clean tmp',
      );

      expect(asker.prompts, isEmpty);
      expect(fakeBash.calls.length, 1);
    });

    test('auto mode: classifier allow executes, deny short-circuits', () async {
      final fakeBash = _RecordingTool('bash');
      final tools = ToolRegistry([fakeBash]);
      final provider = _ScriptedProvider([
        [
          ToolUseBlock(id: 'u1', name: 'bash', input: const {
            'command': 'ls',
          }),
          ToolUseBlock(id: 'u2', name: 'bash', input: const {
            'command': 'rm -rf /',
          }),
        ],
        const [TextBlock('done.')],
      ]);
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      // The classifier's provider answers per call: ls -> ALLOW, rm -> DENY.
      final classifierProvider = _PerCallProvider(['ALLOW', 'DENY']);
      final classifier = PermissionClassifier(classifierProvider);
      final asker = _RecordingAsker([]);

      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: policy,
        asker: modeAwareAsker(
          policy: policy,
          classifier: classifier,
          fallback: asker.ask,
        ),
        system: 'sys',
      );
      final history = <Message>[];
      await agent.run(
        history: history,
        userInput: 'run two commands',
      );

      expect(asker.prompts, isEmpty, reason: 'classifier decided both');
      expect(
          fakeBash.calls.map((c) => c['command']), ['ls'],
          reason: 'the denied rm never reaches execute');
      // The deny surfaces to the model as an error tool_result.
      final results = history
          .lastWhere((m) => m.role == Role.user)
          .content
          .whereType<ToolResultBlock>()
          .toList();
      expect(results.any((r) => r.isError!), isTrue);
      expect(
          results.firstWhere((r) => r.isError!).content,
          contains('Denied by permission policy'));
    });
  });
}

// --- test doubles --------------------------------------------------------

class _ScriptedProvider extends LlmProvider {
  final Queue<List<ContentBlock>> _turns;
  _ScriptedProvider(List<List<ContentBlock>> turns)
      : _turns = Queue.of(turns),
        super('scripted');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    if (_turns.isEmpty) {
      yield const MessageComplete(content: [], stopReason: 'end_turn');
      return;
    }
    final content = _turns.removeFirst();
    final hasTool = content.any((b) => b is ToolUseBlock);
    yield MessageComplete(
      content: content,
      stopReason: hasTool ? 'tool_use' : 'end_turn',
    );
  }
}

class _RecordingTool implements Tool {
  final String _name;
  final List<Map<String, dynamic>> calls = [];
  _RecordingTool(this._name);

  @override
  ToolSchema get schema => ToolSchema(
        name: _name,
        description: 'fake $_name',
        inputSchema: const {'type': 'object'},
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    calls.add(input);
    return const ToolResult('ok');
  }
}

class _PerCallProvider extends LlmProvider {
  final Queue<String> _answers;
  _PerCallProvider(List<String> answers)
      : _answers = Queue.of(answers),
        super('per-call');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    yield TextDelta(
        _answers.isEmpty ? 'ALLOW' : _answers.removeFirst());
  }
}

class _RecordingAsker {
  final List<PermissionResponse> _scripted;
  final List<PermissionPrompt> prompts = [];
  var _idx = 0;
  _RecordingAsker(List<PermissionResponse> scripted) : _scripted = scripted;

  Future<PermissionResponse> ask(PermissionPrompt p) async {
    prompts.add(p);
    if (_idx >= _scripted.length) {
      throw StateError('asker called more times than scripted');
    }
    return _scripted[_idx++];
  }
}

