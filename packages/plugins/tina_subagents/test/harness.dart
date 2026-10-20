/// Shared harness: a parent host (in memory or persisted) with the
/// tools plugin and a sub-agents plugin whose children are built by
/// [Host.child] through [standardChildFactory]. The scripted provider
/// plays the model on both sides — and each host builds its OWN
/// provider, which is the point: no two sessions share an instance.
///
/// [scripts] drives the parent's model turns, one list of turns per
/// provider. [childScripts] drives child providers: each launched child
/// builds its own provider, drawn one turn-list at a time from
/// [childScripts]. Because a launch is non-blocking, children run on
/// their own schedule — giving them their own script queue makes that
/// deterministic instead of interleaving with the parent's model calls.
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
  List<List<List<StreamEvent>>> childScripts = const [],
  SubagentsConfig config = const SubagentsConfig(),
  String? storePath,
  PermissionMode mode = PermissionMode.allowEdits,
  Directory? dir,
  LlmProvider? childProvider,
}) {
  final ws = dir ?? workspace().dir;
  final providers = <ScriptedProvider>[];
  var i = 0;
  var ci = 0;
  // Parent turns draw from [scripts], child turns from [childScripts], one
  // turn-list per provider build. An exhausted queue still answers
  // well-formed, so a test that scripted too few turns ends cleanly
  // instead of hanging.
  List<List<StreamEvent>> next() =>
      i < scripts.length ? scripts[i++] : const [];
  List<List<StreamEvent>> nextChild() =>
      ci < childScripts.length ? childScripts[ci++] : const [];

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
        final p = ScriptedProvider(nextChild());
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
