/// Shared harness: a parent host (in memory or persisted) with the
/// tools plugin and a sub-agents plugin whose children are built by
/// [Host.child] through [standardChildFactory]. The scripted provider
/// plays the model on both sides — and each host builds its OWN
/// provider, which is the point: no two sessions share an instance.
///
/// The [scripts] list is one flat queue of model turns, in the order the
/// run consumes them. Parent turns and child turns draw from the same
/// queue — a spawn interleaves them (parent asks, child runs to the
/// end, parent takes the result), so who consumes which script is part
/// of what the test pins.
library;

import 'package:tina_persistence/tina_persistence.dart';
import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_subagents/tina_subagents.dart';
import 'package:tina_tools/tina_tools.dart';

/// The workspace every test runs in. A fresh temp dir per call.
({String root, Directory dir}) workspace() {
  final dir = Directory.systemTemp.createTempSync('tina-subagents-test-');
  return (root: dir.path, dir: dir);
}

/// Build a parent + plugin wired for tests. Returns the pieces a test
/// drives: the parent host, the plugin, the tools plugin, and every
/// provider built (so scripts and requests can be asserted on).
({
  Host host,
  SubagentsPlugin plugin,
  ToolsPlugin tools,
  List<ScriptedProvider> providers,
  Directory dir,
}) harness({
  required List<List<List<StreamEvent>>> scripts,
  SubagentsConfig config = const SubagentsConfig(),
  String? storePath,
  PermissionMode mode = PermissionMode.allowEdits,
  Directory? dir,
  LlmProvider? childProvider,
}) {
  final ws = dir ?? workspace().dir;
  final providers = <ScriptedProvider>[];
  var i = 0;
  // One flat queue, shared by parent and child providers: the next
  // model turn drawn is the next script, whoever asked for it. An
  // exhausted queue still answers well-formed, so a test that scripted
  // too few turns ends cleanly instead of hanging.
  List<List<StreamEvent>> next() =>
      i < scripts.length ? scripts[i++] : const [];

  final tools = ToolsPlugin(
    workspaceRoot: ws.path,
    tinaDir: Directory('${ws.path}/.tina'),
    mode: mode,
    osSandbox: false,
  );
  final host = Host.start(HostConfig(
    providerFactory: (model) {
      final p = ScriptedProvider(next());
      providers.add(p);
      return p;
    },
    workingDirectory: ws.path,
    plugins: [
      tools,
      if (storePath != null)
        PersistencePlugin(openStore: () => SessionStore.open(storePath)),
    ],
    sessionTitle: 'subagents-test',
  ));
  final plugin = SubagentsPlugin(
    parent: host.context,
    config: config,
    sessionFactory: standardChildFactory(
      parentTools: tools,
      providerFactory: (model) {
        if (childProvider != null) return childProvider;
        final p = ScriptedProvider(next());
        providers.add(p);
        return p;
      },
      model: 'scripted',
      childPlugins: () => [
        if (storePath != null)
          PersistencePlugin(openStore: () => SessionStore.open(storePath))
      ],
    ),
  );
  // The plugin constructed after Host.start mounts itself on the loop —
  // exactly what a composition that builds the plugin from a live
  // session does.
  plugin.mountOn(host.session.loop);
  host.session.loop.addPlugin(plugin);
  return (
    host: host,
    plugin: plugin,
    tools: tools,
    providers: providers,
    dir: ws
  );
}
