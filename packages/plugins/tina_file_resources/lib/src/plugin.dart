/// The plugin: reads the folder on the prompt phase, lists what it found,
/// mounts one tool that fetches a body.
///
/// The listing is names and descriptions only — never bodies — so the
/// prompt carries what the model needs to choose, and the tool carries
/// the rest. A body that lands in the prompt is a bug, not a shortcut:
/// the whole point of the split is that most items stay unread.
///
/// An empty listing adds nothing: no section, no tool. A folder the
/// model should not see an empty announcement of does not get one.
library;

import 'dart:convert' show utf8;

import 'package:tina_engine_2/tina_engine_2.dart';

import 'resource_files.dart';
import 'resources_tool.dart';

/// The knobs. [directory] is the one required fact; the rest have
/// defaults a plain folder needs nothing from.
final class FileResourcesConfig {
  /// The folder to read, absolute.
  final String directory;

  /// First line of the prompt section, e.g. `## Skills`.
  final String heading;

  /// The listing is names and descriptions only; this caps the whole
  /// section's utf8 bytes. When entries no longer fit, the plugin stops
  /// and appends a visible marker naming the omission count — it never
  /// truncates mid-line and never silently drops an entry.
  final int maxListBytes;

  const FileResourcesConfig({
    required this.directory,
    this.heading = '## Resources',
    this.maxListBytes = 2048,
  });
}

/// Contributes the prompt section and the one tool. Mounts the tool
/// itself: the host honors [AgentPlugin.mountOn] without knowing anything else
/// about this plugin.
final class FileResourcesPlugin extends AgentPlugin {
  FileResourcesPlugin(
      {this.id = 'tina/file-resources',
      this.order = 45,
      required FileResourcesConfig config})
      : config = config;

  @override
  final String id;

  /// After subagents (40); a resource list is less pressing still.
  @override
  final int order;

  final FileResourcesConfig config;

  ResourcesTool? _tool;

  /// The last prompt-phase read — including what failed (unreadable,
  /// headerless, duplicated). Null before the first turn. Tests read
  /// this; so can a diagnostics plugin.
  ResourceListing? lastListing;

  /// One sync pass over the folder. Not cached: the prompt phase is the
  /// natural refresh point, a second read per turn buys nothing.
  ResourceListing listing() => readResourceDirectory(config.directory);

  /// The rendered prompt section for [listing], honoring
  /// [FileResourcesConfig.maxListBytes]. Visible over-cap marker,
  /// entries never truncated mid-line.
  String renderSection(ResourceListing listing) {
    final entries = [
      for (final item in listing.items) '- ${item.name} — ${item.description}',
    ];
    final section = [config.heading, '', ...entries].join('\n');
    if (utf8.encode(section).length <= config.maxListBytes) return section;

    // Too big: keep the longest prefix that leaves room for a marker
    // naming what was left out. The marker is the contract — a model
    // that reads a capped list must be able to tell it is capped.
    for (var keep = entries.length - 1; keep >= 0; keep--) {
      final omitted = entries.length - keep;
      final candidate = [
        config.heading,
        '',
        ...entries.take(keep),
        '',
        '(+$omitted more omitted — the listing exceeded '
            'maxListBytes; ask for an item by name)',
      ].join('\n');
      if (utf8.encode(candidate).length <= config.maxListBytes) {
        return candidate;
      }
    }
    // Even the empty list does not fit: say so rather than emit a
    // section that looks complete.
    return '${config.heading}\n\n'
        '(all ${entries.length} items omitted — maxListBytes is too '
        'small to list any)';
  }

  @override
  List<ToolSchema> get tools {
    final listing = lastListing;
    if (listing == null || listing.isEmpty) return const [];
    return [_tool!.schema];
  }

  @override
  void onPrompt(TurnContext c) {
    final read = listing();
    lastListing = read;
    if (read.isEmpty) return; // empty folder, or a missing one: nothing
    c.promptSections.add(renderSection(read));
  }

  @override
  void mountOn(AgentLoop loop) {
    _tool ??= ResourcesTool(this);
    loop.registerExecutor(ResourcesTool.schemaName, _tool!.execute);
  }

  /// The tool's executor body, exposed so the tool stays a thin face:
  /// name → body, or a named error.
  Future<ToolResult> fetch(String name) async {
    final read = listing();
    lastListing = read;
    if (read.missingDirectory) {
      return ToolResult.error(
          '${ResourcesTool.schemaName}: the resource directory '
          '${config.directory} does not exist');
    }
    final item = resourceByName(read, name);
    if (item == null) {
      final available = read.items.map((i) => i.name).join(', ');
      return ToolResult.error(
          '${ResourcesTool.schemaName}: unknown resource "$name" in '
          '${config.directory}. Available: ${available.isEmpty ? 'none' : available}');
    }
    return ToolResult(item.body);
  }
}
