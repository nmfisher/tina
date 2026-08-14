import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import '../summaries/sidecar_repo.dart' show kDefaultPartitionSkip;
import 'region_registry.dart';

/// The region surface for the main agent: discover regions (`list_regions`),
/// read their summaries (`read_summary`), route questions to them
/// (`query_region` / `broadcast_region`), and manage the partition
/// (`allocate_region` / `forget_region`).
///
/// Regions are primed from the summary sidecar at session start (zero LLM
/// calls); a query dispatches ONE one-shot read-only agent — fast, scoped to
/// its directory, with its summary as its knowledge base — whose report comes
/// back as the tool result. Nothing is persisted beyond the summaries
/// themselves.

/// A no-op sink for one-shot region runs: the report text is what matters
/// (returned by the scheduler), not the stream.
class _SilentSink implements AgentSink {
  @override
  void text(String s) {}

  @override
  void newline() {}

  @override
  void toolStart(ToolStartEvent event) {}

  @override
  void toolOutput(ToolOutputEvent event) {}

  @override
  void toolComplete(ToolCompleteEvent event) {}

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {}

  @override
  void activityStart() {}

  @override
  void activityStop() {}
}

/// Parse an optional `llm_provider`/`llm_model` pair from the tool input into
/// a `"provider/model"` reference. Both halves are required (mirrors the
/// delegate tool); either alone is ignored. Returns null when absent.
String? _modelOverride(Map<String, dynamic> input) {
  final provider = (input['llm_provider'] as String?)?.trim();
  final model = (input['llm_model'] as String?)?.trim();
  return (provider != null && provider.isNotEmpty && model != null && model.isNotEmpty)
      ? '$provider/$model'
      : null;
}

/// The system prompt for a region query agent: its identity, its summary as
/// its knowledge base, a staleness warning, and soft directory scoping.
String _regionSystemPrompt(Region r) {
  final summary = r.summary;
  final staleNote = r.stale
      ? 'STALE: the code has changed since this summary was written (last '
          'summarized at commit ${r.commit ?? 'unknown'}). Verify anything '
          'material against the actual code.'
      : 'The summary is current.';
  return '''
You are the region agent for "${r.dir}" in this repository — you know this area of the codebase and you answer the main agent's questions about it. You work read-only and only within ${r.dir}; you never modify anything.

Your knowledge of the region (${r.summary == null ? 'not summarized yet' : 'summary from commit ${r.commit ?? '?'}'}):
${summary ?? '(no summary yet — explore the directory with your tools.)'}

$staleNote

Answer the task concisely and precisely, citing files you looked at. If the task shows the region summary is materially out of date, update it by calling write_summary("${r.dir}", <full new summary>) — never include a tracking header, the tool stamps it.''';
}

/// `repo_structure` — the folder-review surface the main agent uses to design
/// the region layout (the `/index` proposal): an indented tree of directories
/// with file + dart-file counts, a `[package]` marker where a pubspec lives,
/// and a total. Pure file walk, depth-capped.
class RepoStructureTool implements Tool {
  RepoStructureTool(this._regions);

  final RegionRegistry _regions;

  /// Walk depth (levels below the root).
  static const _maxDepth = 3;

  /// Hidden entries and build/tool dirs are never region candidates.
  /// [kDefaultPartitionSkip] is shared with the default partition so the two
  /// surfaces agree; `.git`/`.tina` are walk-specific extras.
  static const _skip = {'.git', '.tina', ...kDefaultPartitionSkip};

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'repo_structure',
        description: 'Review the repository\'s folder structure: an indented '
            'tree of directories (up to 3 levels deep) with file counts, a '
            '[package] marker where a pubspec.yaml lives, and the total. Use '
            'this to decide where region agents belong (skip trivial folders, '
            'merge related ones, split large ones) before calling '
            'allocate_region.',
        // Providers require a JSON-Schema object; an empty map would be
        // rejected on the wire.
        inputSchema: {'type': 'object', 'properties': {}},
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final root = _regions.projectRoot;
    final buf = StringBuffer();
    var totalFiles = 0;
    var totalDart = 0;

    void walk(String rel, int depth) {
      if (depth > _maxDepth) return;
      final dir = Directory(p.join(root, rel));
      if (!dir.existsSync()) return;
      final entries = dir.listSync(followLinks: false)
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final e in entries) {
        final name = p.basename(e.path);
        if (name.startsWith('.') || _skip.contains(name)) continue;
        if (e is! Directory) continue;
        final subRel = rel.isEmpty ? name : '$rel/$name';
        var files = 0;
        var dart = 0;
        for (final f in dir.listSync(followLinks: false)) {
          if (f is! File) continue;
          if (f.path == p.join(dir.path, 'pubspec.yaml')) continue;
          files++;
          if (f.path.endsWith('.dart')) dart++;
        }
        final hasPackage =
            File(p.join(dir.path, 'pubspec.yaml')).existsSync();
        totalFiles += files;
        totalDart += dart;
        buf.writeln('${'  ' * (depth - 1)}$subRel/  '
            '($files file${files == 1 ? '' : 's'}'
            '${dart > 0 ? ', $dart dart' : ''})'
            '${hasPackage ? ' [package]' : ''}');
        walk(subRel, depth + 1);
      }
    }

    walk('', 1);
    if (buf.isEmpty) {
      return ToolResult('The repository has no subdirectories to review.');
    }
    return ToolResult('Repository structure (${totalFiles} files, '
        '$totalDart dart):\n${buf.toString().trimRight()}');
  }
}

/// `list_regions` — the discovery surface: which regions exist, their
/// staleness, and a digest of each summary. Cheap (file + git reads only).
class ListRegionsTool implements Tool {
  ListRegionsTool(this._regions);

  final RegionRegistry _regions;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'list_regions',
        description: 'List the region agents of this repository — one per '
            'summarized directory (the top-level dirs, packages/*/lib, and '
            'any dirs you allocated with allocate_region). Each entry shows '
            'the directory, whether its summary is stale, its model, and a '
            'digest of what it covers. Call this first to discover which '
            'region (if any) owns an area; then query_region for details, or '
            'broadcast_region when you are not sure which region owns a '
            'feature. No regions yet? Run /index or allocate_region.',
        // Providers require a JSON-Schema object; an empty map would be
        // rejected on the wire.
        inputSchema: {'type': 'object', 'properties': {}},
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final regions = _regions.list();
    if (regions.isEmpty) {
      return ToolResult('No regions in this repository yet. Run `/index` to '
          'summarize the default directories, or allocate_region to add a '
          'directory.');
    }
    final lines = StringBuffer()
      ..writeln('${regions.length} region(s):');
    for (final r in regions) {
      final digest = r.summarized
          ? r.summary!.replaceAll(RegExp(r'\s+'), ' ').trim()
          : '(no summary yet — run /index)';
      final clipped = digest.length <= 160 ? digest : '${digest.substring(0, 160)}…';
      lines.writeln('- ${r.dir}'
          '${r.stale ? ' [STALE]' : ''}'
          '${r.model == null ? '' : ' (${r.model})'}');
      lines.writeln('    $clipped');
    }
    return ToolResult(lines.toString());
  }
}

/// `read_summary` — the full summary text of one region.
class ReadSummaryTool implements Tool {
  ReadSummaryTool(this._regions);

  final RegionRegistry _regions;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'read_summary',
        description: 'Read the full summary of one region — what exists and '
            'what is implemented in its directory. Pass the region directory '
            'as `region` (from list_regions). Use before query_region when you '
            'need the region\'s current knowledge without dispatching an '
            'agent.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'region': {
              'type': 'string',
              'description': 'The region directory (e.g. "lib").',
            },
          },
          'required': ['region'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final dir = (input['region'] as String?)?.trim() ?? '';
    final region = _regions.find(dir);
    if (region == null) {
      return ToolResult.error('No region "$dir". Available: '
          '${_regions.list().map((r) => r.dir).join(', ')}.');
    }
    if (!region.summarized) {
      return ToolResult('Region "$dir" has no summary yet — run `/index` or '
          'query_region to have the agent explore it.');
    }
    return ToolResult('--- summary of $dir ---\n'
        '${region.summary}\n'
        '---\n'
        '${region.stale ? 'STALE — the code changed since commit ${region.commit ?? '?'}.' : 'Current as of ${region.commit ?? '?'}.'}');
  }
}

/// `query_region` — dispatch one fast, read-only agent to a region and get
/// its report.
class QueryRegionTool implements Tool {
  QueryRegionTool(this._regions, this._scheduler, {required this.parentReference});

  final RegionRegistry _regions;
  final SubAgentScheduler _scheduler;

  /// The main agent's `"provider/model"` — the inherit fallback when neither
  /// the region's allocation nor the tool input specifies a model.
  final String parentReference;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'query_region',
        description: 'Ask one region agent a question about its directory. '
            'The agent is fast, read-only, scoped to its region, and primed '
            'with the region\'s summary. Pass the region directory as '
            '`region` (from list_regions) and the question as `task`. Use '
            'this instead of blanket searches when the question is about one '
            'area. Optionally pass llm_provider + llm_model to override the '
            'model for this query.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'region': {
              'type': 'string',
              'description': 'The region directory (e.g. "lib").',
            },
            'task': {
              'type': 'string',
              'description': 'The question or task for the region agent.',
            },
            'llm_provider': {'type': 'string'},
            'llm_model': {'type': 'string'},
          },
          'required': ['region', 'task'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final dir = (input['region'] as String?)?.trim() ?? '';
    final task = (input['task'] as String?)?.trim() ?? '';
    if (task.isEmpty) return ToolResult.error('query_region needs a `task`.');
    final region = _regions.find(dir);
    if (region == null) {
      return ToolResult.error('No region "$dir". Available: '
          '${_regions.list().map((r) => r.dir).join(', ')}.');
    }
    return _runRegionQuery(region, task, cancelSignal, input);
  }

  /// Shared by [QueryRegionTool] and [BroadcastRegionTool].
  Future<ToolResult> _runRegionQuery(
    Region region,
    String task,
    Future<void>? cancelSignal,
    Map<String, dynamic> input,
  ) async {
    final result = await _scheduler.runStandalone(
      systemPrompt: _regionSystemPrompt(region),
      task: task,
      parentReference: parentReference,
      modelReference: _modelOverride(input) ?? _regions.modelFor(region.dir),
      cancelSignal: cancelSignal,
      sink: _SilentSink(),
      toolProfile: ToolProfile.readOnly,
      includeDelegate: false,
    );
    if (result.isError) {
      return ToolResult.error('region agent for ${region.dir} failed: '
          '${result.text}');
    }
    return ToolResult(result.text);
  }
}

/// `broadcast_region` — the "which of you owns this?" fan-out: every region
/// agent answers, the main agent synthesizes.
class BroadcastRegionTool implements Tool {
  BroadcastRegionTool(this._regions, this._scheduler,
      {required this.parentReference});

  final RegionRegistry _regions;
  final SubAgentScheduler _scheduler;
  final String parentReference;

  /// Mirrors the delegate tool's per-call fan-out cap.
  static const kMaxRegions = 8;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'broadcast_region',
        description: 'Ask EVERY region agent the same question (the "which of '
            'you owns this feature?" fan-out). Use when you are not sure which '
            'region covers an area, or when a feature spans several. Each '
            'region answers briefly; you synthesize. Cost: one fast agent run '
            'per region. Optionally pass llm_provider + llm_model to override '
            'the model for this broadcast.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'task': {
              'type': 'string',
              'description': 'The question to ask every region agent.',
            },
            'llm_provider': {'type': 'string'},
            'llm_model': {'type': 'string'},
          },
          'required': ['task'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final task = (input['task'] as String?)?.trim() ?? '';
    if (task.isEmpty) return ToolResult.error('broadcast_region needs a `task`.');
    final regions = _regions.list();
    if (regions.isEmpty) {
      return ToolResult('No regions in this repository yet. Run `/index` or '
          'allocate_region first.');
    }
    if (regions.length > kMaxRegions) {
      return ToolResult.error('Too many regions (${regions.length}); '
          'broadcast_region supports at most $kMaxRegions. Query them '
          'individually.');
    }
    final results = await Future.wait(regions.map((r) async {
      final out = await _scheduler.runStandalone(
        systemPrompt: _regionSystemPrompt(r),
        task: task,
        parentReference: parentReference,
        modelReference:
            _modelOverride(input) ?? _regions.modelFor(r.dir),
        cancelSignal: cancelSignal,
        sink: _SilentSink(),
        toolProfile: ToolProfile.readOnly,
        includeDelegate: false,
      );
      return (dir: r.dir, out: out);
    }));
    final buf = StringBuffer();
    for (final r in results) {
      buf.writeln('### ${r.dir}');
      buf.writeln(r.out.isError ? '(agent failed: ${r.out.text})' : r.out.text);
      buf.writeln();
    }
    return ToolResult(buf.toString().trimRight());
  }
}

/// `allocate_region` — give a directory its own region agent. A cheap
/// partition write: the summary is generated by the fleet when `/index` runs
/// (the user approves the proposed layout there), not inline.
class AllocateRegionTool implements Tool {
  AllocateRegionTool(this._regions);

  final RegionRegistry _regions;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'allocate_region',
        description: 'Give a directory its own region agent: it gets a '
            'persistent summary and can be queried with query_region. Pass '
            'the repo-relative directory as `dir` (any nesting is fine). '
            'Optionally pass llm_provider + llm_model to give this region a '
            'dedicated fast model; otherwise it inherits the [regions] config '
            'default, then the main model. The summary is generated when '
            '`/index` runs — allocate several regions to design a layout, '
            'then run /index to approve and summarize.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'dir': {
              'type': 'string',
              'description': 'Repo-relative directory, e.g. "packages/foo/lib".',
            },
            'llm_provider': {'type': 'string'},
            'llm_model': {'type': 'string'},
          },
          'required': ['dir'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final dir = (input['dir'] as String?)?.trim() ?? '';
    if (dir.isEmpty) return ToolResult.error('allocate_region needs a `dir`.');
    if (!_regions.allocate(dir, model: _modelOverride(input))) {
      return ToolResult.error('No such directory in this repo: "$dir".');
    }
    return ToolResult('Allocated a region agent for "$dir"'
        '${_modelOverride(input) == null ? '' : ' (${_modelOverride(input)})'}. '
        'Its summary is generated when `/index` runs (which approves the '
        'layout); you can also read_summary or query_region it right away — '
        'it will explore on its own.');
  }
}

/// `forget_region` — remove a region (its directory drops out of the
/// partition; the summary file is removed on the next refresh).
class ForgetRegionTool implements Tool {
  ForgetRegionTool(this._regions);

  final RegionRegistry _regions;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'forget_region',
        description: 'Remove a region agent for a directory. The directory '
            'stops being summarized (its summary file is cleaned up on the '
            'next /index run). Pass the region directory as `dir`.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'dir': {
              'type': 'string',
              'description': 'The region directory (e.g. "lib").',
            },
          },
          'required': ['dir'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final dir = (input['dir'] as String?)?.trim() ?? '';
    final region = _regions.find(dir);
    if (region == null) {
      return ToolResult.error('No region "$dir". Available: '
          '${_regions.list().map((r) => r.dir).join(', ')}.');
    }
    _regions.forget(dir);
    return ToolResult('Forgot region "$dir". Its summary will be cleaned up '
        'on the next `/index` run.');
  }
}
