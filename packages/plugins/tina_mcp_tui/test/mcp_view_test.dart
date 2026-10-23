import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_mcp_tui/tina_mcp_tui.dart';
import 'package:tina_settings/tina_settings.dart';

final class _Io implements Stdio {
  final input = StreamController<List<int>>();
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

final class _Presentation {
  _Presentation(McpManagement mcp) {
    attachment = ConsoleAttachment.attach(McpView(mcp), context);
  }
  final io = _Io();
  late final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24, split: false),
  );
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  late final context = ConsoleContext(screen: screen, editor: editor);
  late final ConsoleAttachment attachment;
  List<SettingControl> get fields => context.settings.sections.single.build();
  SettingText text(String id) =>
      fields.whereType<SettingText>().singleWhere((field) => field.id == id);
  SettingToggle toggle(String id) =>
      fields.whereType<SettingToggle>().singleWhere((field) => field.id == id);
  void dispose() {
    attachment.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  }
}

final class _CallingProvider implements LlmProvider {
  String? tool;
  bool _called = false;
  void select(String? value) {
    tool = value;
    _called = false;
  }

  @override
  String get model => 'fixture';
  @override
  void close() {}
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    if (!_called && tool != null) {
      _called = true;
      final name = tools
          .singleWhere(
            (schema) =>
                schema.describe?.call({}).title ==
                'fixture: ${tool![0].toUpperCase()}${tool!.substring(1)}',
          )
          .name;
      yield* Stream.fromIterable(
        scriptedReply(
          '',
          calls: [ToolUseBlock(id: 'call', name: name, input: {})],
        ),
      );
    } else {
      yield* Stream.fromIterable(scriptedReply('done'));
    }
  }
}

void main() {
  late Directory root;
  late McpConfigStore store;
  late McpPlugin plugin;
  late _Presentation first;
  late McpConnector connector;
  late McpApprover approver;
  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-view-');
    final config = File('${root.path}/config')
      ..writeAsStringSync('[default]\nmodel = "untouched"\n');
    store = McpConfigStore(config.path);
    connector = (_, _) => throw StateError('Editing must not connect');
    approver =
        ({
          required operation,
          required target,
          required reason,
          context = const {},
        }) async => throw StateError('Editing must not request tool approval');
    plugin = McpPlugin.configured(
      store: store,
      workingDirectory: root.path,
      connect: (config, workspace) => connector(config, workspace),
      approve:
          ({
            required operation,
            required target,
            required reason,
            context = const {},
          }) async => approver(
            operation: operation,
            target: target,
            reason: reason,
            context: context,
          ),
    );
    first = _Presentation(plugin.management!);
  });
  tearDown(() async {
    first.dispose();
    await plugin.shutdown();
    root.deleteSync(recursive: true);
  });

  test(
    'local settings retain defaults, validation and secret editor fields',
    () async {
      await first.text('add_server').change(' blender ');
      expect(store.read().single.command, 'blender-mcp');
      expect(store.read().single.enabled, false);
      expect(first.toggle('blender/enabled').scopes, {SettingScope.global});
      await first.toggle('blender/enabled').change(true);
      await first.text('blender/command').change('/path/to/blender-mcp');
      expect(store.read().single.command, '/path/to/blender-mcp');
      expect(store.read().single.enabled, true);
      expect(first.text('blender/timeout_ms').read(), '60,000');
      await first.text('blender/timeout_ms').change('120,000');
      expect(store.read().single.timeout!.inMilliseconds, 120000);
      await first.text('blender/timeout_ms').change('0');
      expect(store.read().single.timeout, isNull);
      expect(first.text('blender/env').secret, isTrue);
      await first.text('blender/env').change(r'{"TOKEN":"${TOKEN}"}');
      expect(store.read().single.environment, {'TOKEN': r'${TOKEN}'});
      final saved = File(store.path).readAsStringSync();
      for (final invalid in ['-1', '1.5', 'oops']) {
        expect(
          () => first.text('blender/timeout_ms').change(invalid),
          throwsFormatException,
        );
      }
      expect(
        () => first.text('blender/args').change('[2]'),
        throwsFormatException,
      );
      expect(
        () => first.text('blender/env').change('{"TOKEN":2}'),
        throwsFormatException,
      );
      expect(
        () => first.text('add_server').change('blender'),
        throwsStateError,
      );
      expect(
        () => first.text('add_server').change('Bad Name'),
        throwsFormatException,
      );
      expect(File(store.path).readAsStringSync(), saved);
      expect(saved, contains('untouched'));
      expect(plugin.tools, isEmpty);
      first.attachment.dispose();
      expect(first.context.settings.sections, isEmpty);
    },
  );

  test(
    'HTTP editor preserves endpoint rules and secret header fields',
    () async {
      await first.text('add_http_server').change('remote');
      expect(store.read().single.url, 'http://localhost:8000/mcp');
      expect(store.read().single.enabled, isFalse);
      expect(
        first.fields.any((field) => field.id == 'remote/command'),
        isFalse,
      );
      expect(first.text('remote/headers').secret, isTrue);
      await first.text('remote/url').change('https://example.test/mcp');
      await first
          .text('remote/headers')
          .change(r'{"Authorization":"Bearer ${TOKEN}"}');
      expect(store.read().single.headers, {
        'Authorization': r'Bearer ${TOKEN}',
      });
      expect(
        () => first.text('remote/url').change('file:///bad'),
        throwsFormatException,
      );
      expect(
        () => first.text('remote/headers').change('{"Host":"bad"}'),
        throwsFormatException,
      );
    },
  );

  test(
    'two editors merge old controls into latest saved server and refresh both',
    () async {
      final second = _Presentation(plugin.management!);
      addTearDown(second.dispose);
      var firstRefreshes = 0, secondRefreshes = 0;
      final releaseFirst = first.context.settings.listen(
        () => firstRefreshes++,
      );
      final releaseSecond = second.context.settings.listen(
        () => secondRefreshes++,
      );
      addTearDown(releaseFirst);
      addTearDown(releaseSecond);
      await first.text('add_server').change('fixture');
      expect(firstRefreshes, 1);
      expect(secondRefreshes, 1);
      final oldCommand = first.text('fixture/command');
      final oldToggle = second.toggle('fixture/enabled');
      await second.text('fixture/timeout_ms').change('123');
      await oldCommand.change('changed-command');
      await oldToggle.change(true);
      expect(store.read().single.timeout!.inMilliseconds, 123);
      expect(store.read().single.command, 'changed-command');
      expect(store.read().single.enabled, isTrue);
      final snapshot = firstRefreshes;
      first.attachment.dispose();
      final afterDetach = firstRefreshes;
      await second.text('fixture/args').change('["--changed"]');
      expect(firstRefreshes, afterDetach);
      expect(
        afterDetach,
        snapshot + 1,
        reason: 'removal refreshes its own registry',
      );
      expect(second.context.settings.sections, hasLength(1));
      expect(store.read().single.arguments, ['--changed']);
    },
  );

  test('status actions write to the invoking view', () async {
    await first.text('add_server').change('fixture');
    final second = _Presentation(plugin.management!);
    addTearDown(second.dispose);
    final untouched = first.io.output.toString();
    await second.fields.whereType<SettingAction>().single.invoke();
    expect(second.io.output.toString(), contains('MCP fixture:'));
    expect(first.io.output.toString(), untouched);
  });

  test(
    'views share one connection and preserve approvals and in-flight calls',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:tina_mcp/tina_mcp.dart'),
      );
      final fixture = library!
          .resolve('../test/fixtures/server.py')
          .toFilePath();
      final eventsFile = File('${root.path}/events');
      final processes = <Process>[];
      connector = (config, workspace) async {
        final transport =
            await connectMcp(config, workspace) as StdioMcpTransport;
        processes.add(transport.process);
        return transport;
      };
      var approvals = 0;
      approver =
          ({
            required operation,
            required target,
            required reason,
            context = const {},
          }) async {
            approvals++;
            return ApprovalDecision.allowAlways;
          };
      await first.text('add_server').change('fixture');
      await first.text('fixture/command').change('python3');
      await first
          .text('fixture/args')
          .change(jsonEncode([fixture, eventsFile.path]));
      await first.toggle('fixture/enabled').change(true);
      final second = _Presentation(plugin.management!);
      addTearDown(second.dispose);
      final provider = _CallingProvider()..select('screenshot');
      final loop = AgentLoop(provider: provider, plugins: [plugin]);
      loop.mountPlugin(plugin);
      final firstCall = await loop.runTurn(const Input('first', id: 'one'));
      expect(firstCall.stopReason, StopReason.complete);
      expect(processes, hasLength(1));
      expect(approvals, 2);
      expect(plugin.tools, hasLength(10));
      for (final view in [first, second]) {
        expect(
          view.fields.whereType<SettingAction>().single.label,
          contains('5 tools connected'),
        );
      }
      first.attachment.dispose();
      provider.select('screenshot');
      await loop.runTurn(const Input('same call', id: 'two'));
      expect(processes, hasLength(1));
      expect(
        approvals,
        3,
        reason: 'every call reaches shared authorization while the connection survives detach',
      );

      provider.select('slow');
      final active = loop.runTurn(const Input('slow call', id: 'three'));
      addTearDown(() async {
        loop.cancel('cleanup');
        await active.timeout(const Duration(seconds: 3));
      });
      await _waitFor(
        () => eventsFile.readAsLinesSync().any((line) {
          final event = jsonDecode(line) as Map;
          return event['method'] == 'tools/call' &&
              event['params']['name'] == 'slow';
        }),
      );
      await second.toggle('fixture/enabled').change(false);
      second.attachment.dispose();
      expect(loop.running, isTrue);
      expect((await active).stopReason, StopReason.complete);
      expect(
        plugin.tools,
        hasLength(10),
        reason: 'configuration must not change active turn schemas',
      );
      expect(processes, hasLength(1));
      expect(approvals, 4);
      final replacement = _Presentation(plugin.management!);
      addTearDown(replacement.dispose);
      expect(replacement.toggle('fixture/enabled').read(), isFalse);
      provider.select(null);
      await loop.runTurn(const Input('apply disabled server', id: 'four'));
      expect(plugin.tools, isEmpty);
      expect(plugin.serverStatus, {'fixture': 'Disabled'});
      expect(
        replacement.fields.whereType<SettingAction>().single.label,
        contains('Disabled'),
      );
      await processes.single.exitCode.timeout(const Duration(seconds: 3));
    },
  );
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
