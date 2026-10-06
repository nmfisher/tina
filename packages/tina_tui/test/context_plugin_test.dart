import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_tools/tina_tools.dart';

List<String> texts(Iterable<Message> messages) => [
      for (final m in messages)
        for (final b in m.content.whereType<TextBlock>()) b.text,
    ];

final class EditingProvider extends LlmProvider {
  EditingProvider(this.context) : super('scripted');
  final ContextPlugin Function() context;
  final requests = <List<Message>>[];

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(List.of(messages));
    if (requests.length == 1) {
      yield const MessageComplete(
          content: [TextBlock('discard this output')], stopReason: 'end_turn');
    } else if (requests.length == 2) {
      final file = context().mirrorFile!;
      final document = jsonDecode(file.readAsStringSync()) as Map;
      document['messages'] = [(document['messages'] as List).last];
      yield const ToolCallStart(id: 'edit-context', name: 'write');
      yield MessageComplete(content: [
        ToolUseBlock(id: 'edit-context', name: 'write', input: {
          'filePath': file.path,
          'content': jsonEncode(document),
        })
      ], stopReason: 'tool_use');
    } else {
      yield const MessageComplete(
          content: [TextBlock('done')], stopReason: 'end_turn');
    }
  }
}

void main() {
  late Directory root, workspace;
  late File config;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-context-app-');
    workspace = Directory('${root.path}/workspace')..createSync();
    config = File('${root.path}/global')
      ..writeAsStringSync('[default]\nmodel="scripted"\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  AssemblyOptions options({String? resume}) => AssemblyOptions(
      workingDirectory: workspace.path,
      configPath: config.path,
      sessionId: resume);
  void enable() {
    final local = File('${workspace.path}/.tina/config');
    local.parent.createSync(recursive: true);
    local.writeAsStringSync('[plugins.overrides]\n"tina/context" = true\n');
  }

  ContextPlugin context(TuiAssembly app) =>
      app.host.plugins.whereType<ContextPlugin>().single;

  test('context is disabled by default with no extra file grants', () {
    final app = TuiAssembly.start(
        options: options(), providerFactory: (_) => ScriptedProvider([]));
    addTearDown(app.close);
    expect(app.host.plugins.whereType<ContextPlugin>(), isEmpty);
    expect(app.tools.sandbox.grants.isEmpty, isTrue);
    expect(app.pluginSettings.state('tina/context').enabled, isFalse);
    expect(app.pluginSettings.state('tina/context-tui').enabled, isFalse);
    expect(app.commands['context'], isNull);
    expect(
        app.pluginSettings.registry.definition('tina/context').live, isFalse);
  });

  test('viewer binds to the loaded context and can be toggled live', () {
    enable();
    final app = TuiAssembly.start(
        options: options(), providerFactory: (_) => ScriptedProvider([]));
    addTearDown(app.close);
    final plugin = context(app);
    final before = app.host.session.loop.log.length;
    app.pluginSettings.apply(
        'tina/context-tui', true, PluginScope.workspace, app.pluginManager);
    expect(app.pluginManager.lastError, isNull);
    expect(app.commands['context'], isNotNull);
    expect(app.host.plugins.whereType<ContextTuiPlugin>().single.context,
        same(plugin));
    expect(app.host.session.loop.log.length, before);
    expect(
        () => app.pluginSettings.apply(
            'tina/context', false, PluginScope.workspace, app.pluginManager),
        throwsArgumentError);
    app.pluginSettings.apply(
        'tina/context-tui', false, PluginScope.workspace, app.pluginManager);
    expect(app.commands['context'], isNull);
    expect(context(app), same(plugin));
    expect(app.tools.sandbox.grants.length, 1);
  });

  test('viewer requires context and waits for its pending activation', () {
    final app = TuiAssembly.start(
        options: options(), providerFactory: (_) => ScriptedProvider([]));
    addTearDown(app.close);
    expect(
        () => app.pluginSettings.apply(
            'tina/context-tui', true, PluginScope.workspace, app.pluginManager),
        throwsArgumentError);
    app.pluginSettings
        .apply('tina/context', true, PluginScope.workspace, app.pluginManager);
    app.pluginSettings.apply(
        'tina/context-tui', true, PluginScope.workspace, app.pluginManager);
    expect(app.commands['context'], isNull);
    expect(app.host.plugins.whereType<ContextPlugin>(), isEmpty);
    final restarted = TuiAssembly.start(
        options: options(), providerFactory: (_) => ScriptedProvider([]));
    addTearDown(restarted.close);
    expect(restarted.commands['context'], isNotNull);
    expect(restarted.host.plugins.whereType<ContextTuiPlugin>().single.context,
        same(context(restarted)));
  });

  test(
      'workspace opt-in edits through real file tools and restores from SQLite',
      () async {
    enable();
    late TuiAssembly app;
    final provider = EditingProvider(() => context(app));
    app =
        TuiAssembly.start(options: options(), providerFactory: (_) => provider);
    final plugin = context(app);
    final file = plugin.mirrorFile!;
    expect(app.tools.sandbox.grants.allows(file.resolveSymbolicLinksSync()),
        isTrue);
    expect(app.tools.sandbox.grants.length, 1);
    // No access is granted to adjacent files or the protected session store.
    expect(app.tools.sandbox.grants.allows('${file.parent.path}/other.json'),
        isFalse);
    await expectLater(
        app.tools.sandbox
            .guard(FileOp.read, '${workspace.path}/.tina/sessions.db'),
        throwsA(isA<SandboxViolation>()));
    await app.host.send('old task');
    final result = await app.host.send('current task');
    expect(result.stopReason, StopReason.complete);
    expect(plugin.lastReceipt!.status, ContextEditStatus.accepted);
    expect(texts(provider.requests.last),
        ['current task', 'Context edit accepted.']);
    expect(
        provider.requests.last
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .single
            .isError,
        isFalse);
    expect(texts(app.host.session.loop.derive().messages),
        ['old task', 'discard this output', 'current task', 'done']);
    final id = app.host.session.id;
    app.close();
    expect(file.existsSync(), isFalse);

    final resumedProvider = ScriptedProvider([scriptedReply('resumed')]);
    final resumed = TuiAssembly.start(
        options: options(resume: id), providerFactory: (_) => resumedProvider);
    addTearDown(resumed.close);
    expect(context(resumed).mirrorFile!.path, isNot(file.path));
    expect(context(resumed).workingContext.revision, 1);
    expect(texts(context(resumed).workingContext.messages),
        ['current task', 'done']);
    await resumed.host.send('continue');
    expect(texts(resumedProvider.requests.single.messages),
        ['current task', 'done', 'continue']);
  });

  test('panels get distinct mirrors and grants', () {
    enable();
    final first = TuiAssembly.start(
        options: options(), providerFactory: (_) => ScriptedProvider([]));
    final second = first.newSession(null);
    addTearDown(first.close);
    addTearDown(second.close);
    final one = context(first).mirrorFile!.resolveSymbolicLinksSync();
    final two = context(second).mirrorFile!.resolveSymbolicLinksSync();
    expect(one, isNot(two));
    expect(first.tools.sandbox.grants.allows(one), isTrue);
    expect(first.tools.sandbox.grants.allows(two), isFalse);
    expect(second.tools.sandbox.grants.allows(two), isTrue);
    expect(second.tools.sandbox.grants.allows(one), isFalse);
  });

  test('automatic and manual compaction stay paused through pending disable',
      () async {
    enable();
    final provider = ScriptedProvider([
      scriptedReply('one'),
      scriptedReply('two'),
      scriptedReply('three'),
      scriptedReply('summary must not run'),
    ]);
    final app =
        TuiAssembly.start(options: options(), providerFactory: (_) => provider);
    addTearDown(app.close);
    for (final prompt in ['one', 'two', 'three']) {
      await app.host.send(prompt);
    }
    expect(provider.callCount, 3);
    expect(app.host.plugins.whereType<CompactionPlugin>().single.canCompact!(),
        isFalse);
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    app.pluginSettings
        .apply('tina/context', false, PluginScope.workspace, app.pluginManager);
    expect(app.host.plugins.whereType<ContextPlugin>(), hasLength(1));
    expect(app.pluginSettings.changeStatus('tina/context', app.pluginManager),
        'pending restart');
    await app.handleCommand('/compact');
    expect(provider.callCount, 3);
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
  });

  test('enabling context stays pending restart and keeps compaction available',
      () async {
    final provider = ScriptedProvider([
      scriptedReply('one'),
      scriptedReply('two'),
      scriptedReply('three'),
      scriptedReply('summary'),
    ]);
    final app =
        TuiAssembly.start(options: options(), providerFactory: (_) => provider);
    addTearDown(app.close);
    for (final prompt in ['one', 'two', 'three']) {
      await app.host.send(prompt);
    }
    app.pluginSettings
        .apply('tina/context', true, PluginScope.workspace, app.pluginManager);
    expect(app.host.plugins.whereType<ContextPlugin>(), isEmpty);
    await app.handleCommand('/compact');
    expect(provider.callCount, 4);
    expect(app.host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });
}
