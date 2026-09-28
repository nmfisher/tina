/// Wiring a real sub-agents plugin onto a real session: the load-time
/// handovers become one closure.
///
/// [SubagentsPlugin] receives a child-session factory at construction;
/// this function builds the standard one. Everything the child inherits
/// is read **from the parent's own assembly** — the parent's `ToolsPlugin`
/// (its mode and workspace root), the parent's provider factory and
/// model, the parent's store path — so a child cannot receive values its
/// parent does not have. The restricted plugin set is explicit here: the
/// tools, **not** the sub-agents plugin (a child never spawns), and no
/// persistence plugin (the child's own log is its persistence; it writes
/// to the same store file as its own session, or nowhere).
///
/// The parent's plugin must already be mounted — the closure reads the
/// boundary from it. Given a read-only parent, the child's boundary is
/// built read-only: a write in the child is denied by its own sandbox,
/// never asked.
library;

import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';

import 'subagents_plugin.dart';

ChildSessionFactory standardChildFactory({
  required ToolsPlugin parentTools,
  required ProviderFactory providerFactory,
  String model = 'scripted',
  List<AgentPlugin> Function()? childPlugins,
  List<AgentPlugin> extraPlugins = const [],
}) {
  return (SubagentsPlugin plugin) {
    if (extraPlugins.any((p) => p is SubagentsPlugin)) {
      throw ArgumentError(
          'a child plugin set must not contain another SubagentsPlugin');
    }
    // The child's facts, from the plugin; the inherited world, from the
    // parent's assembly. Host.child builds the provider through the
    // factory, mounts exactly this plugin set, and records the depth on
    // the child's session details.
    return Host.child(
      depth: plugin.childDepth,
      sessionId: plugin.nextChildId(),
      workingDirectory: parentTools.workingDirectory,
      providerFactory: providerFactory,
      model: model,
      plugins: [
        ToolsPlugin(
          workspaceRoot: parentTools.workingDirectory,
          tinaDir: Directory('${parentTools.workingDirectory}/.tina'),
          mode: parentTools.mode,
          osSandbox: false,
        ),
        ...?childPlugins?.call(),
        ...extraPlugins,
      ],
    );
  };
}
