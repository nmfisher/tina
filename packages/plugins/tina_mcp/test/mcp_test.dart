import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_tools/tina_tools.dart';

class Channel implements ApprovalChannel {
  int requests = 0;
  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    requests++;
    ticket.respond(ApprovalDecision.allow);
  }
}

class SafetyProvider extends LlmProvider implements StructuredOutputProvider {
  SafetyProvider() : super('safety');
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      throw StateError('Expected structured verdict');
  @override
  Stream<StreamEvent> sendStructured(
      {required String system,
      required List<Message> messages,
      required JsonOutputSchema output}) async* {
    yield* Stream.fromIterable(scriptedReply('{"decision":"ALLOW"}'));
  }
}

class CallingProvider extends LlmProvider {
  CallingProvider(this.tool, {this.input = const {}}) : super('test');
  String? tool;
  Map<String, dynamic> input;
  final requests = <List<ToolSchema>>[];
  bool _call = true;
  void next(String? tool, [Map<String, dynamic> input = const {}]) {
    this.tool = tool;
    this.input = input;
    _call = true;
  }

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(List.of(tools));
    if (_call && tool != null) {
      _call = false;
      final name = tools
          .singleWhere((s) =>
              s.describe?.call({}).title ==
                  'fixture: ${tool![0].toUpperCase()}${tool!.substring(1)}' ||
              s.describe?.call({}).title == 'fixture: $tool')
          .name;
      yield ToolCallStart(id: 'call${requests.length}', name: name);
      yield MessageComplete(content: [
        ToolUseBlock(id: 'call${requests.length}', name: name, input: input)
      ], stopReason: 'tool_use');
    } else {
      yield const MessageComplete(
          content: [TextBlock('done')], stopReason: 'end_turn');
    }
  }
}

void main() {
  late Directory directory;
  late String fixture;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('tina-mcp-test-');
    final library = await Isolate.resolvePackageUri(
        Uri.parse('package:tina_mcp/tina_mcp.dart'));
    fixture = library!.resolve('../test/fixtures/server.py').toFilePath();
  });
  tearDown(() => directory.deleteSync(recursive: true));
  McpServerConfig config({int? timeout, String name = 'fixture'}) =>
      McpServerConfig(name, {
        'command': 'python3',
        'args': [fixture, '${directory.path}/events'],
        if (timeout != null) 'timeout_ms': timeout,
      });
  List<Map<String, dynamic>> events() => File('${directory.path}/events')
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
  Future<void> eventually(bool Function() test) async {
    for (var i = 0; i < 200 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(test(), true);
  }

  Future<McpClient> client({int? timeout}) async {
    final transport =
        await connectMcp(config(timeout: timeout), directory.path);
    final client = McpClient(transport,
        timeout: timeout == null
            ? const Duration(seconds: 3)
            : Duration(milliseconds: timeout),
        workspaceUri: Uri.directory(directory.path).toString());
    addTearDown(client.close);
    await client.initialize();
    return client;
  }

  Iterable<ToolResultBlock> results(Outcome outcome) =>
      outcome.messages.expand((m) => m.content).whereType<ToolResultBlock>();

  test('real stdio: initialize, paginated tools, roots, ping and image results',
      () async {
    final c = await client();
    final tools = await c.list('tools/list', 'tools');
    expect(tools.map((t) => t['name']),
        ['screenshot', 'mutate', 'slow', 'error', 'explode']);
    expect(c.instructions, 'Use the fixture tools.');
    final value = mcpToolResult(
        await c.request('tools/call', {'name': 'screenshot', 'arguments': {}}));
    expect(value.content, contains('Blender 📷'));
    expect(value.content, contains('"objects":3'));
    expect(value.images.single.mimeType, 'image/png');
    await eventually(
        () => events().any((e) => e['id'] == 103 && e['error'] != null));
    expect(
        events().singleWhere(
            (e) => e['id'] == 101 && e['result'] != null)['result'],
        {});
    expect(
        events().singleWhere((e) => e['id'] == 102 && e['result'] != null)[
            'result']['roots'][0]['uri'],
        Uri.directory(directory.path).toString());
    await c.close();
    expect(c.closed, true);
  });

  test('first turn discovers and executes MCP tools; image survives log replay',
      () async {
    final provider = CallingProvider('screenshot');
    final approvals = <Map<String, Object?>>[];
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [config()],
        approve: (
            {required operation,
            required target,
            required reason,
            context = const {}}) async {
          approvals.add(context);
          return ApprovalDecision.allow;
        });
    addTearDown(plugin.shutdown);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    final outcome =
        await loop.runTurn(const Input('take screenshot', id: 'one'));
    expect(outcome.stopReason, StopReason.complete);
    expect(approvals.single['mcp_tool'], 'screenshot');
    expect(provider.requests.first, hasLength(10));
    expect(results(outcome).single.images.single.data, 'aGVsbG8=');
    final replayed = loop.log.map((e) => SessionEntry.fromJson(e.toJson()));
    final image = replayed
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolResultBlock>()
        .single
        .images
        .single;
    expect(image.data, 'aGVsbG8=');
  });

  test(
      'deny executes nothing; always is exact, conversation scoped, and survives notification',
      () async {
    var answer = ApprovalDecision.deny;
    var count = 0;
    final provider = CallingProvider('mutate', input: {'value': 'a'});
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [config()],
        approve: (
            {required operation,
            required target,
            required reason,
            context = const {}}) async {
          count++;
          return answer;
        });
    addTearDown(plugin.shutdown);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    final denied = await loop.runTurn(const Input('deny', id: 'one'));
    expect(results(denied).single.isError, true);
    expect(events().where((e) => e['method'] == 'tools/call'), isEmpty);
    answer = ApprovalDecision.allowAlways;
    provider.next('mutate', {'value': 'a'});
    final changed = await loop.runTurn(const Input('allow', id: 'two'));
    expect(changed.stopReason, StopReason.complete,
        reason: 'notifications must not change the pinned tools mid-turn');
    expect(count, 2);
    provider.next('mutate', {'value': 'a'});
    await loop.runTurn(const Input('same', id: 'three'));
    expect(count, 2);
    expect(
        provider.requests.last
            .where((t) => t.describe?.call({}).title == 'fixture: New_Tool'),
        hasLength(1));
    provider.next('mutate', {'value': 'b'});
    await loop.runTurn(const Input('different arguments', id: 'four'));
    expect(count, 3);
    provider.next('screenshot');
    await loop.runTurn(const Input('different tool', id: 'five'));
    expect(count, 4);
    loop.removePlugin(plugin.id);
    await plugin.shutdown();
    expect(loop.toolSchema(provider.requests.first.first.name), isNull);
  });

  test('cancellation sends notifications/cancelled and ignores a late response',
      () async {
    final c = await client();
    final cancelled = Completer<void>();
    final request = c.request('tools/call', {'name': 'slow', 'arguments': {}},
        whenCancelled: cancelled.future);
    final assertion = expectLater(
        request,
        throwsA(isA<McpException>()
            .having((e) => e.message, 'message', contains('cancelled'))));
    await eventually(() => events().any((e) => e['method'] == 'tools/call'));
    cancelled.complete();
    await assertion;
    await eventually(
        () => events().any((e) => e['method'] == 'notifications/cancelled'));
    expect(await c.request('ping', {}), {});
  });

  test('timeout cancels once and does not replay side effects', () async {
    final c = await client(timeout: 250);
    await expectLater(
        c.request('tools/call', {'name': 'slow', 'arguments': {}}),
        throwsA(isA<McpException>().having((e) => e.message, 'message',
            contains('may still have completed'))));
    await eventually(
        () => events().any((e) => e['method'] == 'notifications/cancelled'));
    expect(events().where((e) => e['method'] == 'tools/call'), hasLength(1));
  });

  test('server exit fails pending requests and close kills the process',
      () async {
    final c = await client();
    final process = (c.transport as StdioMcpTransport).process;
    await expectLater(
        c.request('tools/call', {'name': 'explode', 'arguments': {}}),
        throwsA(isA<McpException>()));
    expect(await process.exitCode, 7);
    expect(c.closed, true);
  });

  test('shutdown rejects in-flight requests and closes a real server',
      () async {
    final c = await client();
    final process = (c.transport as StdioMcpTransport).process;
    final pending = c.request('tools/call', {'name': 'slow', 'arguments': {}});
    final assertion = expectLater(pending, throwsA(isA<McpException>()));
    await eventually(() => events().any((e) => e['method'] == 'tools/call'));
    await c.close();
    await assertion;
    await process.exitCode.timeout(const Duration(seconds: 2));
  });

  test('tool errors, resources and prompts round-trip', () async {
    final c = await client();
    final error = mcpToolResult(
        await c.request('tools/call', {'name': 'error', 'arguments': {}}));
    expect(error.isError, true);
    expect(error.content, 'Fixture failure');
    expect((await c.list('resources/list', 'resources')).single['uri'],
        'fixture://scene');
    expect(
        (await c.request(
                'resources/read', {'uri': 'fixture://scene'}))['contents'][0]
            ['text'],
        'Scene data');
    expect((await c.list('prompts/list', 'prompts')).single['name'], 'scene');
    expect(
        (await c.request('prompts/get', {'name': 'scene'}))['messages'][0]
            ['content']['text'],
        'Describe scene');
  });

  test('unavailable server does not prevent ordinary conversation', () async {
    final provider = ScriptedProvider([scriptedReply('still works')]);
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [
              McpServerConfig(
                  'missing', {'command': '${directory.path}/not-installed'})
            ],
        approve: (
                {required operation,
                required target,
                required reason,
                context = const {}}) async =>
            ApprovalDecision.deny);
    addTearDown(plugin.shutdown);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    expect((await loop.runTurn(const Input('hello', id: 'one'))).stopReason,
        StopReason.complete);
    expect(plugin.serverStatus, {'missing': 'Unavailable'});
    expect(provider.callCount, 1);
  });

  test(
      'all manual modes ask for MCP calls; auto uses the existing safety judge',
      () async {
    final channel = Channel();
    final approvals = ApprovalsPlugin(channel: channel);
    final tools = ToolsPlugin(
        workspaceRoot: directory.path, tinaDir: directory, osSandbox: false);
    tools.modePolicy.approvals = approvals;
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [config()],
        approve: tools.modePolicy.request);
    final provider = CallingProvider('mutate');
    final loop =
        AgentLoop(provider: provider, plugins: [approvals, tools, plugin]);
    for (final p in [approvals, tools, plugin]) loop.mountPlugin(p);
    addTearDown(() async {
      approvals.closeSession();
      tools.closeSession();
      await plugin.shutdown();
    });
    for (final mode in [
      PermissionMode.ask,
      PermissionMode.readOnly,
      PermissionMode.allowEdits
    ]) {
      tools.mode = mode;
      provider.next('mutate', {'value': mode.label});
      final outcome = await loop.runTurn(Input('run', id: mode.label));
      expect(outcome.stopReason, StopReason.complete);
      expect(results(outcome).single.isError, false);
    }
    expect(channel.requests, 3);
    tools.modePolicy.classifier = PermissionClassifier(() => SafetyProvider());
    tools.mode = PermissionMode.auto;
    provider.next('mutate', {'value': 'auto'});
    final automatic = await loop.runTurn(const Input('run', id: 'auto'));
    expect(results(automatic).single.isError, false);
    expect(channel.requests, 3, reason: 'allowed auto verdict must not prompt');
  });

  test('server disable closes it and removes its schemas on the next turn',
      () async {
    var selected = config();
    Process? process;
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [selected],
        connect: (configuration, workspace) async {
          final transport =
              await connectMcp(configuration, workspace) as StdioMcpTransport;
          process = transport.process;
          return transport;
        },
        approve: (
                {required operation,
                required target,
                required reason,
                context = const {}}) async =>
            ApprovalDecision.allow);
    addTearDown(plugin.shutdown);
    final provider = CallingProvider(null);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    await loop.runTurn(const Input('connect', id: 'one'));
    expect(provider.requests.single, isNotEmpty);
    selected = selected.withValue('enabled', false);
    await loop.runTurn(const Input('disconnect', id: 'two'));
    expect(provider.requests.last, isEmpty);
    expect(plugin.serverStatus, {'fixture': 'Disabled'});
    await process!.exitCode.timeout(const Duration(seconds: 2));
  });
}
