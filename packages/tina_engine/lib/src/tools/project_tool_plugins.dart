import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent/project_tool_scope.dart';
import '../agent/tool_profile.dart';
import '../runtime/plugin.dart';
import 'bash_tool.dart';
import 'brave_search.dart';
import 'edit_tool.dart';
import 'fetch_tool.dart';
import 'git_tool.dart';
import 'glob_tool.dart';
import 'grep_tool.dart';
import 'ls_tool.dart';
import 'project_capabilities.dart';
import 'read_tool.dart';
import 'search_tool.dart';
import 'stat_tool.dart';
import 'tavily_search.dart';
import 'tool.dart';
import 'web_search.dart';
import 'which_tool.dart';
import 'write_summary_tool.dart';
import 'write_tool.dart';

/// The frozen project tool catalog — the tools the runtime registry exposes,
/// in exactly this order. `web_search` (registered by the web-search plugin
/// when an API key is configured) joins after the catalog.
const List<String> kProjectToolCatalog = [
  'read',
  'write',
  'edit',
  'fetch',
  'bash',
  'search',
  'grep',
  'glob',
  'ls',
  'stat',
  'which',
  'git',
];

const _braveKeyEnv = 'BRAVE_API_KEY';
const _tavilyKeyEnv = 'TAVILY_API_KEY';

/// Composition plugin that builds the project's [ProjectCapabilities] via
/// [ProjectCapabilities.build] (confined) and exposes it under
/// [projectCapabilitiesServiceKey].
PluginDescriptor projectCapabilitiesPlugin({
  required String projectRoot,
  required Map<String, String> env,
  bool sandboxEnabled = true,
  bool sandboxNet = false,
  bool sandboxReadOnly = false,
}) =>
    PluginDescriptor(
      id: 'tina.engine.project-capabilities',
      provides: [projectCapabilitiesServiceKey],
      factory: FnPluginFactory((context) {
        final caps = ProjectCapabilities.build(
          projectRoot: projectRoot,
          env: env,
          confineFiles: true,
          sandboxEnabled: sandboxEnabled,
          sandboxNet: sandboxNet,
          sandboxReadOnly: sandboxReadOnly,
        );
        return caps;
      }),
    );

/// Composition plugin that assembles the [ProjectToolScope] from the already
/// built capabilities. Requires [projectCapabilitiesServiceKey], so it
/// activates strictly after the capabilities plugin.
PluginDescriptor projectToolScopePlugin() => PluginDescriptor(
      id: 'tina.engine.project-tool-scope',
      requires: {projectCapabilitiesServiceKey},
      provides: [projectToolScopeServiceKey],
      factory: FnPluginFactory((context) {
        final caps = context.require(projectCapabilitiesServiceKey);
        return ProjectToolScope.fromCapabilities(caps);
      }),
    );

/// Service key under which the write-summary plugin exposes the sidecar
/// capture tool. `write_summary` is composed by the runtime but is
/// deliberately NOT a registry contribution: the base registry
/// ([toolRegistryFromScope]) stays the frozen catalog plus `web_search`, and
/// the profiles compose the sidecar tool themselves (read-only/full sets and
/// the policy candidates — exactly where it appeared before).
final ServiceKey<Tool> writeSummaryToolServiceKey =
    ServiceKey<Tool>('tina.engine.project_write_summary_tool');

/// Plugin id for the project tool named [name].
String projectToolPluginId(String name) => 'tina.tool.$name';

/// One plugin per project tool, wired from [caps] exactly as the tool scope
/// wired them by hand: file-tool roots, sandbox fs, backup stores, the bash
/// process runner and the summaries sidecar only when [caps.confineFiles];
/// the shared mutation lock on write/edit; search/which/git always carry
/// their root/env wiring.
///
/// Declared order is the frozen catalog ([kProjectToolCatalog]) followed by
/// the sidecar `write_summary` and then `web_search`.
List<PluginDescriptor> projectToolPlugins(ProjectCapabilities caps) => [
      _toolPlugin('read', caps, _buildRead),
      _toolPlugin('write', caps, _buildWrite),
      _toolPlugin('edit', caps, _buildEdit),
      _toolPlugin('fetch', caps, _buildFetch),
      _toolPlugin('bash', caps, _buildBash),
      _toolPlugin('search', caps, _buildSearch),
      _toolPlugin('grep', caps, _buildGrep),
      _toolPlugin('glob', caps, _buildGlob),
      _toolPlugin('ls', caps, _buildLs),
      _toolPlugin('stat', caps, _buildStat),
      _toolPlugin('which', caps, _buildWhich),
      _toolPlugin('git', caps, _buildGit),
      _writeSummaryPlugin(caps),
      _webSearchPlugin(caps),
    ];

/// Wraps one tool builder as a plugin: the factory builds the tool and
/// registers it as the scope's contribution under the tool's own name.
PluginDescriptor _toolPlugin(
  String name,
  ProjectCapabilities caps,
  Tool Function(ProjectCapabilities caps) build,
) =>
    PluginDescriptor(
      id: projectToolPluginId(name),
      factory: FnPluginFactory((context) {
        final tool = build(caps);
        context.register(tool, id: tool.schema.name);
        return tool;
      }),
    );

ReadTool _buildRead(ProjectCapabilities caps) {
  final tool = ReadTool();
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..fs = caps.fileSystem!;
}

WriteTool _buildWrite(ProjectCapabilities caps) {
  // The shared per-file lock: always wired, confined or not.
  final tool = WriteTool()..mutationLock = caps.mutationLock;
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..fs = caps.fileSystem!
    ..backupStore = caps.backups!;
}

EditTool _buildEdit(ProjectCapabilities caps) {
  final tool = EditTool()..mutationLock = caps.mutationLock;
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..fs = caps.fileSystem!
    ..backupStore = caps.backups!;
}

FetchTool _buildFetch(ProjectCapabilities caps) => FetchTool();

BashTool _buildBash(ProjectCapabilities caps) {
  final tool = BashTool();
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..processRunner = caps.processRunner;
}

SearchTool _buildSearch(ProjectCapabilities caps) =>
    SearchTool(repoRoot: caps.projectRoot);

GrepTool _buildGrep(ProjectCapabilities caps) {
  final tool = GrepTool();
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..fs = caps.fileSystem!
    ..sandbox = caps.fileSystem!;
}

GlobTool _buildGlob(ProjectCapabilities caps) {
  final tool = GlobTool();
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..sandbox = caps.fileSystem!;
}

LsTool _buildLs(ProjectCapabilities caps) {
  final tool = LsTool();
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..sandbox = caps.fileSystem!;
}

StatTool _buildStat(ProjectCapabilities caps) {
  final tool = StatTool();
  if (!caps.confineFiles) return tool;
  return tool
    ..projectRoot = caps.projectRoot
    ..sandbox = caps.fileSystem!;
}

WhichTool _buildWhich(ProjectCapabilities caps) =>
    WhichTool(environment: caps.environment);

GitTool _buildGit(ProjectCapabilities caps) =>
    GitTool(workingDirectory: caps.projectRoot);

PluginDescriptor _writeSummaryPlugin(ProjectCapabilities caps) =>
    PluginDescriptor(
      id: projectToolPluginId('write-summary'),
      provides: [writeSummaryToolServiceKey],
      factory: FnPluginFactory((context) {
        final tool = WriteSummaryTool();
        if (caps.confineFiles) {
          // The per-directory summaries sidecar:
          // `<projectRoot>/.tina/summaries` — project-local (so it tracks
          // this repo, under the gitignored `.tina/`), and distinct from the
          // global `~/.tina` data tree the sandbox denies. Summaries reflect
          // committed main-repo HEAD, so the sidecar is pinned to the
          // project, not the user's home.
          tool.sidecarRoot =
              Directory(p.join(caps.projectRoot, '.tina', 'summaries'));
          tool.projectRoot = caps.projectRoot;
        }
        return tool;
      }),
    );

PluginDescriptor _webSearchPlugin(ProjectCapabilities caps) =>
    PluginDescriptor(
      id: projectToolPluginId('web-search'),
      factory: FnPluginFactory((context) {
        final env = caps.environment;
        final braveKey = env[_braveKeyEnv];
        final tavilyKey = env[_tavilyKeyEnv];
        if ((braveKey == null || braveKey.isEmpty) &&
            (tavilyKey == null || tavilyKey.isEmpty)) {
          // No provider configured: the plugin contributes nothing.
          return Object();
        }
        // Both providers answer the `web_search` tool name — a user only
        // needs one index, and a configured Tavily key supersedes Brave (the
        // precedence the last-wins registry used to produce). Only the
        // winning instance is contributed, first under its provider id, then
        // under the merged `web_search` id the assembly exposes; contributing
        // both providers would be a duplicate tool name, which the assembly
        // rejects outright.
        final WebSearchTool tool;
        final String providerId;
        if (tavilyKey != null && tavilyKey.isNotEmpty) {
          tool = WebSearchTool(TavilySearchProvider(tavilyKey));
          providerId = 'web_search.tavily';
        } else {
          tool = WebSearchTool(BraveSearchProvider(braveKey!));
          providerId = 'web_search.brave';
        }
        context.register(tool, id: providerId);
        context.register(tool, id: 'web_search');
        return tool;
      }),
    );

/// Assembles the [ToolRegistry] an activated plugin scope exposes: every
/// [Tool] contribution, in declared order — the frozen catalog
/// ([kProjectToolCatalog]), with uncatalogued tools (`web_search`) keeping
/// their registration order after it — and [stripForSafeMode] applied when
/// [safeMode] is on.
///
/// Activation runs factories alphabetically by plugin id, so the scope's raw
/// contribution order is NOT the declared order; the catalog rank wins here.
///
/// Two DIFFERENT tools with the same schema name throw [StateError]: the
/// registry's map is deliberately last-wins, but assembly must be explicit
/// about collisions instead of silently overwriting. One instance
/// re-exposed under a second contribution id (the web-search plugin's
/// provider id and its merged `web_search` id) counts once, at its last id.
ToolRegistry toolRegistryFromScope(PluginScope scope, {bool safeMode = false}) {
  final contributions = scope.contributions;

  // Last contribution index per tool instance.
  final lastIndexOf = <Tool, int>{};
  for (var i = 0; i < contributions.length; i++) {
    final contribution = contributions[i].contribution;
    if (contribution is Tool) lastIndexOf[contribution] = i;
  }

  final collected = <(int, Tool)>[];
  final byName = <String, Tool>{};
  for (var i = 0; i < contributions.length; i++) {
    final contribution = contributions[i];
    final tool = contribution.contribution;
    if (tool is! Tool) continue;
    if (lastIndexOf[tool] != i) continue; // re-exposition; kept at its last id
    final name = tool.schema.name;
    if (byName.containsKey(name)) {
      throw StateError(
          'duplicate tool name "$name" in scope "${scope.name}": contribution '
          '"${contribution.id}" (plugin ${contribution.pluginId}) collides '
          'with an already-registered tool of the same name');
    }
    byName[name] = tool;
    collected.add((i, tool));
  }

  int rank(Tool tool) {
    final index = kProjectToolCatalog.indexOf(tool.schema.name);
    return index == -1 ? kProjectToolCatalog.length : index;
  }

  collected.sort((a, b) {
    final byRank = rank(a.$2).compareTo(rank(b.$2));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });

  final tools = collected.map((entry) => entry.$2).toList();
  return ToolRegistry(safeMode ? stripForSafeMode(tools) : tools);
}
