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
import 'package:tina_services/tina_services.dart';

import 'subagents_plugin.dart';

/// The standard child factory for [plugin] on a parent session whose
/// tools live in [parentTools]. [providerFactory] and [model] are the
/// parent host's — the child's provider is built per child from the
/// same factory, never shared with the parent's instance.
/// [storePath] persists each child as its own session (pass the
/// parent's store path from the composition); null keeps children in
/// memory. [extraPlugins] rides onto the child after the tools — the
/// composition's hook for prompt-only plugins worth inheriting; it must
/// not contain another [SubagentsPlugin] (that would let a child spawn,
/// defeating the depth limit) — enforced here, loudly. [services] is
/// the session's shared locator; the child's tools plugin publishes its
/// own boundary under it only if the parent shared one at all — pass
/// null for a child that shares nothing.
ChildSessionFactory standardChildFactory({
  required ToolsPlugin parentTools,
  required ProviderFactory providerFactory,
  String model = 'scripted',
  String? storePath,
  List<AgentPlugin> extraPlugins = const [],
  Services? services,
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
      mode: parentTools.mode,
      providerFactory: providerFactory,
      model: model,
      plugins: [
        ToolsPlugin(
          workspaceRoot: parentTools.workingDirectory,
          tinaDir: Directory('${parentTools.workingDirectory}/.tina'),
          mode: parentTools.mode,
          osSandbox: false,
          services: services,
        ),
        ...extraPlugins,
      ],
      storePath: storePath,
    );
  };
}
