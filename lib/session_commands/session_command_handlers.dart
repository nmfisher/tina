import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import '../summaries/summary_index.dart';
import '../pipeline/pipeline_commands.dart';
import 'command_context.dart';

/// The slash-command handlers, lifted out of [SessionController] so they can be
/// read and tested in isolation. Operates purely through a [CommandContext] —
/// no input loop, no host of its own. [dispatch] is the entry point the
/// controller calls each input line; it echoes the command, runs any registered
/// hook, and switches on the command word exactly as the controller used to.
class SessionCommandHandlers {
  final CommandContext ctx;
  SessionCommandHandlers(this.ctx);

  /// Every recognized slash command, in display order. The single source of
  /// truth for both [dispatch] and the `/` command-completion palette
  /// ([CommandCompletionProvider]).
  static const List<String> allCommands = [
    '/exit', '/quit', '/help', '/clear', '/compact', '/auto-compact',
    '/permissions', '/sessions', '/session', '/resume', '/model', '/settings',
    '/prompts', '/spawn', '/branch', '/image', '/index', '/workflow', '/output',
  ];

  Future<CmdResult> dispatch(String trimmed) async {
    final word = trimmed.split(RegExp(r'\s+')).first;
    if (!allCommands.contains(word)) {
      if (word.startsWith('/')) {
        ctx.active.host.showMessage(
            '$word: unknown command\n',
            style: HostMessageStyle.error);
        return const CmdHandled();
      }
      return const CmdNotCommand();
    }

    ctx.active.host.showMessage('$trimmed\n', style: HostMessageStyle.user);
    ctx.active.host.showSeparator();

    // Run any registered hook for this command before the default action. The
    // hook may prepare or clear state that the default handler then acts on.
    final hook = ctx.commandHooks[word];
    if (hook != null) {
      await hook();
    }

    switch (word) {
      case '/exit':
      case '/quit':
        return const CmdExit();
      case '/help':
        _printHelp();
      case '/clear':
        await _handleClear();
      case '/compact':
        await _handleCompact();
      case '/auto-compact':
        _handleAutoCompact(trimmed);
      case '/permissions':
        _printPermissions();
      case '/sessions':
        await _printSavedSessions();
      case '/session':
        await _handleSessionCommand(trimmed);
      case '/resume':
        await _handleResume(trimmed);
      case '/model':
        _handleModel(trimmed);
      case '/settings':
        await _handleSettings();
      case '/prompts':
        await _handlePrompts();
      case '/spawn':
        await _handleSpawn();
      case '/branch':
        await _handleBranch();
      case '/image':
        await _handleImage(trimmed);
      case '/index':
        return await _handleIndex();
      case '/workflow':
        await handleWorkflowCommand(ctx, trimmed);
      case '/output':
        await _handleOutput(trimmed);
    }
    return const CmdHandled();
  }

  /// `/output [n]` — show the full output of a capped tool call. No argument
  /// shows the most recent; `/output 2` shows the second-most-recent, etc.
  Future<void> _handleOutput(String trimmed) async {
    final parts = trimmed.split(RegExp(r'\s+'));
    final int index;
    if (parts.length > 1) {
      final n = int.tryParse(parts[1]);
      if (n == null || n < 1) {
        ctx.active.host.showMessage(
            'usage: /output [n] — full output of the most recent capped tool '
            'call, or the n-th (newest first).\n',
            style: HostMessageStyle.warning);
        return;
      }
      index = n - 1;
    } else {
      index = 0; // the most recent.
    }
    final open = ctx.openToolOutput;
    if (open == null) {
      ctx.active.host.showMessage(
          '/output needs the interactive TUI.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open(index);
  }

  Future<void> _handleSettings() async {
    final open = ctx.openSettings;
    if (open == null) {
      ctx.active.host.showMessage(
          '/settings needs the interactive TUI; edit ~/.tina/config '
          '(or `tina --init-config`) instead.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open();
  }

  Future<void> _handlePrompts() async {
    final open = ctx.openPrompts;
    if (open == null) {
      ctx.active.host.showMessage(
          '/prompts needs the interactive TUI; edit the [prompts.<role>] '
          'table in ~/.tina/config instead.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open();
  }

  Future<void> _handleSpawn() async {
    final open = ctx.openSpawn;
    if (open == null) {
      ctx.active.host.showMessage(
          '/spawn needs the interactive TUI to show the model picker.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open();
  }

  Future<void> _handleBranch() async {
    final open = ctx.openBranch;
    if (open == null) {
      ctx.active.host.showMessage(
          '/branch needs the interactive TUI to show the model + role pickers.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open();
  }

  Future<void> _handleImage(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[1].isEmpty) {
      ctx.active.host.showMessage('usage: /image <path>\n');
      return;
    }
    final open = ctx.openImage;
    if (open == null) {
      ctx.active.host.showMessage(
          '/image needs the interactive TUI to render.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open(parts[1]);
  }

  Future<void> _handleSessionCommand(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length == 1 || parts[1] == 'list') {
      _printLiveSessions();
      return;
    }
    switch (parts[1]) {
      case 'new':
        String? providerId;
        String? model;
        if (parts.length >= 3) {
          final spec = parts[2];
          final colon = spec.indexOf(':');
          if (colon >= 0) {
            providerId = _parseProviderId(spec.substring(0, colon));
            model = spec.substring(colon + 1);
          } else {
            providerId = _parseProviderId(spec);
            if (providerId == null) model = spec;
          }
        }
        await ctx.newSession(providerId: providerId, model: model);
      case 'switch':
        if (parts.length < 3) {
          // No id given — open the picker if the TUI wired one, else usage.
          final open = ctx.openSessionPicker;
          if (open != null) {
            await open();
          } else {
            ctx.active.host.showMessage('usage: /session switch <id>\n');
          }
          return;
        }
        final id = _resolveLiveId(parts[2]);
        if (id == null) {
          ctx.active.host.showMessage('no unique session matching "${parts[2]}"\n',
              style: HostMessageStyle.error);
          return;
        }
        ctx.switchSession(id);
      case 'close':
        if (parts.length < 3) {
          ctx.active.host.showMessage('usage: /session close <id>\n');
          return;
        }
        _closeSession(parts[2]);
      case 'rename':
        if (parts.length < 4) {
          ctx.active.host.showMessage(
              'usage: /session rename <id> <new-label>\n');
          return;
        }
        _renameSession(parts[2], parts.sublist(3).join(' '));
      default:
        ctx.active.host.showMessage('usage: /session '
            '[list | new [provider:model] | switch <id> | close <id> | '
            'rename <id> <label>]\n');
    }
  }

  void _renameSession(String token, String newLabel) {
    if (newLabel.isEmpty) {
      ctx.active.host.showMessage('label cannot be empty\n',
          style: HostMessageStyle.error);
      return;
    }
    final id = _resolveLiveId(token);
    if (id == null) {
      ctx.active.host.showMessage('no unique session matching "$token"\n',
          style: HostMessageStyle.error);
      return;
    }
    ctx.sessionManager.all.firstWhere((x) => x.id == id).label = newLabel;
    ctx.active.host.showMessage('(renamed ${_shortId(id)} to "$newLabel")\n',
        style: HostMessageStyle.dim);
    ctx.onSessionsChanged?.call();
  }

  void _closeSession(String token) {
    final id = _resolveLiveId(token);
    if (id == null) {
      ctx.active.host.showMessage('no unique session matching "$token"\n',
          style: HostMessageStyle.error);
      return;
    }
    if (id == ctx.sessionManager.activeId) {
      ctx.active.host.showMessage(
          'cannot close the active session — switch away first\n',
          style: HostMessageStyle.error);
      return;
    }
    final s = ctx.sessionManager.all.firstWhere((x) => x.id == id);
    if (s.isRunning) {
      ctx.active.host.showMessage(
          'session is running — switch to it and press ESC first\n',
          style: HostMessageStyle.error);
      return;
    }
    ctx.sessionManager.close(id);
    ctx.active.host.showMessage('(closed ${_shortId(id)})\n',
        style: HostMessageStyle.dim);
    ctx.onSessionsChanged?.call();
  }

  void _printLiveSessions() {
    for (final s in ctx.sessionManager.listSessions()) {
      final marker = s.isActive ? '* ' : '  ';
      final running = s.isRunning ? ' (running)' : '';
      ctx.active.host.showMessage('$marker${s.id}  ');
      ctx.active.host.showMessage('${s.label}  ${s.msgCount}msg$running\n',
          style: HostMessageStyle.dim);
    }
  }

  /// Resolve a session id from a token by exact match, then unique prefix,
  /// then unique substring (so a short tail of the id is enough to switch).
  String? _resolveLiveId(String token) {
    final ids = ctx.sessionManager.all.map((s) => s.id).toList();
    if (ids.contains(token)) return token;
    var matches = ids.where((id) => id.startsWith(token)).toList();
    if (matches.length == 1) return matches.first;
    matches = ids.where((id) => id.contains(token)).toList();
    if (matches.length == 1) return matches.first;
    return null;
  }

  /// Parse a provider id or alias from a `/session new` spec. Returns null
  /// when [s] isn't a known provider, so a bare model name is treated as a
  /// model rather than a provider. Accepts the built-in ids plus the
  /// `claude`/`gpt` aliases.
  String? _parseProviderId(String s) {
    final lower = s.toLowerCase();
    const aliases = {'claude': 'anthropic', 'gpt': 'openai'};
    if (aliases.containsKey(lower)) return aliases[lower]!;
    return const {
      'anthropic',
      'gemini',
      'openai',
      'deepseek',
      'glm',
      'qwen',
      'grok',
      'mistral',
      'tencent',
    }.contains(lower)
        ? lower
        : null;
  }

  static String _shortId(String id) =>
      id.length > 6 ? id.substring(id.length - 6) : id;

  Future<void> _handleClear() async {
    final s = ctx.active;
    s.history.clear();
    s.host.clear();
    s.host.showMessage('(history cleared)\n', style: HostMessageStyle.dim);
    s.agent.budget = s.agent.budget?.resetSession();
    final rec = s.recorder;
    if (rec != null && rec.isInitialized) {
      await rec.startFresh();
    }
  }

  Future<void> _handleCompact() async {
    final s = ctx.active;
    await s.agent.compact(s.history);
    final rec = s.recorder;
    if (rec != null) {
      try {
        await rec.replace(s.history);
      } catch (e) {
        s.host.showMessage('session write failed: $e\n',
            style: HostMessageStyle.error);
      }
    }
  }

  void _handleAutoCompact(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      ctx.active.host.showMessage(
          ctx.autoCompactThreshold == 0
              ? 'auto-compact: off\n'
              : 'auto-compact: ${ctx.autoCompactThreshold} tokens '
                  '(keeping ${ctx.autoCompactPreserveRecent} recent turns)\n',
          style: HostMessageStyle.dim);
      return;
    }
    final arg = parts[1].toLowerCase();
    if (arg == 'off' || arg == '0') {
      ctx.autoCompactThreshold = 0;
      ctx.active.host.showMessage('auto-compact: off\n',
          style: HostMessageStyle.dim);
      return;
    }
    final n = int.tryParse(arg);
    if (n == null || n < 0) {
      ctx.active.host.showMessage(
          'usage: /auto-compact [<number>|off]  (0 disables)\n',
          style: HostMessageStyle.error);
      return;
    }
    ctx.autoCompactThreshold = n;
    ctx.active.host.showMessage(
        'auto-compact: $n tokens (applies from the next turn)\n',
        style: HostMessageStyle.dim);
  }

  void _printHelp() {
    ctx.active.host.showMessage('Commands:\n'
        '  /help          show this list\n'
        '  /branch        fork the active conversation into a new panel '
        '(copies its history)\n'
        '  /clear         reset this session\'s history\n'
        '  /compact       summarize history to free context\n'
        '  /auto-compact  show/set the auto-compact threshold (off|<n>)\n'
        '  /model         pick a provider/model for the active session\n'
        '  /image <path>  render an image in the focused panel\n'
        '  /index         refresh the per-directory summary index '
        '(staleness-aware)\n'
        '  /workflow      list/show/new/edit/run DOT pipelines '
        '(/workflow show|new|edit|run <name>)\n'
        '  /permissions   show current permission rules\n'
        '  /sessions      list saved (on-disk) sessions\n'
        '  /session       list live sessions; new/switch/close\n'
        '  /resume <id>   load a saved session into the active session\n'
        '  /settings      reconfigure providers/models/tiers (applies on restart)\n'
        '  /prompts       edit each agent role\'s system prompt (applies on restart)\n'
        '  /exit          quit\n'
        'ESC cancels the active session\'s in-flight response.\n');
  }

  void _printPermissions() {
    final policy = ctx.active.policy;
    ctx.active.host.showMessage('defaults:\n');
    final keys = policy.defaults.keys.toList()..sort();
    for (final k in keys) {
      ctx.active.host.showMessage('  $k: ${policy.defaults[k]!.name}\n',
          style: HostMessageStyle.dim);
    }
    if (policy.staticRules.isNotEmpty) {
      ctx.active.host.showMessage('cli rules:\n');
      for (final r in policy.staticRules) {
        ctx.active.host.showMessage('  $r\n', style: HostMessageStyle.dim);
      }
    }
    if (policy.sessionRules.isNotEmpty) {
      ctx.active.host.showMessage('session memory:\n');
      for (final r in policy.sessionRules) {
        ctx.active.host.showMessage('  $r\n', style: HostMessageStyle.dim);
      }
    } else if (policy.staticRules.isEmpty) {
      ctx.active.host.showMessage('(no rules; defaults only)\n',
          style: HostMessageStyle.dim);
    }
  }

  Future<void> _printSavedSessions() async {
    if (ctx.sessionStore == null) {
      ctx.active.host.showMessage('(no session store available)\n',
          style: HostMessageStyle.dim);
      return;
    }
    final List<SessionMeta> sessions;
    try {
      sessions = await ctx.sessionStore!.listSessions();
    } catch (e) {
      ctx.active.host.showMessage('failed to list sessions: $e\n',
          style: HostMessageStyle.error);
      return;
    }
    if (sessions.isEmpty) {
      ctx.active.host.showMessage('(no saved sessions)\n',
          style: HostMessageStyle.dim);
      return;
    }
    final current = ctx.active.recorder?.sessionId;
    for (final s in sessions) {
      final marker = s.id == current ? '* ' : '  ';
      final stamp = _shortStamp(s.updatedAt);
      ctx.active.host.showMessage('$marker${s.id}  $stamp  ${s.messageCount}msg  ');
      ctx.active.host.showMessage('${s.title}\n', style: HostMessageStyle.dim);
    }
  }

  Future<void> _handleResume(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[1].isEmpty) {
      ctx.active.host.showMessage('usage: /resume <id>  (see /sessions)\n');
      return;
    }
    await ctx.resumeIntoActive(parts[1]);
  }

  Future<void> _handleModel(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length > 1) {
      ctx.active.host.showMessage(
          'usage: /model  (opens the picker)\n',
          style: HostMessageStyle.error);
      return;
    }
    final open = ctx.openModelPicker;
    if (open == null) {
      ctx.active.host.showMessage(
          'model: ${ctx.active.provider.model}\n');
      return;
    }
    await open();
  }

  static String _shortStamp(DateTime t) {
    final l = t.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${pad(l.month)}-${pad(l.day)} '
        '${pad(l.hour)}:${pad(l.minute)}';
  }

  /// `/index` — refresh the per-directory summary sidecar, staleness-aware.
  ///
  /// A pure-git probe ([SummaryIndex.status], no LLM) decides what to do:
  /// first run → the LIVE main agent designs the region layout (a `CmdRun`
  /// proposal turn) and the user approves it on the next `/index`; nothing
  /// stale → report up to date and confirm before a full re-run; partly stale
  /// → report the stale dirs and re-run just those; everything stale → index
  /// all. The fleet runs via [SummaryIndex.refresh] (race-free
  /// manifest+commit). Status is posted to the host as notices.
  ///
  /// When [CommandContext.summaryIndex] is null (no composition available),
  /// degrades to the ad-hoc in-chat review ([_indexPrompt]).
  Future<CmdResult> _handleIndex() async {
    final idx = ctx.summaryIndex;
    if (idx == null) {
      ctx.active.host.showMessage(
        'summary sidecar unavailable; falling back to an ad-hoc review\n',
        style: HostMessageStyle.dim);
      return CmdRun(_indexPrompt);
    }
    return runIndexDance(
      host: ctx.active.host,
      summaryIndex: idx,
      confirm: ctx.confirm,
    );
  }

  /// The fixed prompt `/index` injects into the active conversation when the
  /// sidecar service is unavailable (degraded mode). The main agent reviews the
  /// repo structure and delegates (at most 2) sub-agents to summarize areas —
  /// reusing the normal `delegate` flow, no sidecar wiring. The "at most 2" cap
  /// is enforced by instruction, not structurally.
  static const _indexPrompt = '''
Review the structure of this repository. Identify its main areas / subsystems, then spawn AT MOST 2 sub-agents (via `delegate`) — each summarizing one area of the repo you choose. Keep the partition to two areas or fewer.

Each sub-agent should report a concise summary of what its area does, its key types/functions, and how it fits with the rest of the repo. Cite concrete file paths. Do not summarize more than two areas.''';
}

/// The first-run `/index` proposal prompt: the live main agent reviews the
/// repo structure and designs the region layout (which folders get index
/// agents), allocating freely — the user approves the layout when `/index`
/// runs again, and then the fleet summarizes exactly those regions.
const String _proposalPrompt = '''
No region index exists for this repository yet. Design one: review the folder structure with `repo_structure`, then decide which folders deserve a region agent — a persistent summary of what exists and is implemented there, served by a fast agent that answers questions about that folder.

Use your judgment: skip folders that are too small or trivial to matter; merge closely-related folders into one region; split large, dense folders if they cover several concerns. For every folder you choose, call `allocate_region` with the folder's path (optionally llm_provider + llm_model for a dedicated fast model).

When you are done, report the proposed layout — the folders you allocated and a one-line reason for each — and end your response with: run `/index` again to approve this layout and generate the summaries.''';

/// The `/index` staleness dance, factored out of [SessionCommandHandlers] so the
/// headless runner (`bin/tina.dart --non-interactive -p /index`) can reuse it
/// without a [SessionController]: probe staleness (pure git, no LLM), then
/// branch — index all on a first run / when everything is stale; re-run only the
/// stale dirs when partly stale; report up-to-date and confirm (when [confirm]
/// is wired, i.e. the TUI) before a full re-run. The fleet runs via
/// [SummaryIndex.refresh]; notices go to [host].
Future<CmdResult> runIndexDance({
  required HostInterface host,
  required SummaryIndex summaryIndex,
  Future<bool> Function(String prompt)? confirm,
}) async {
  final status = await summaryIndex.status();
  if (status.totalDirs == 0) {
    host.showMessage('No directories to index.\n');
    return const CmdHandled();
  }

  // First run in the TUI: the MAIN AGENT designs the region layout before any
  // fleet run. No allocations yet → hand it a proposal turn (CmdRun runs the
  // prompt through the normal turn path); allocations exist but nothing is
  // summarized → the user approves the proposed layout, then the fleet runs.
  // Headless passes confirm == null and keeps the deterministic default
  // partition below.
  if (status.firstRun && confirm != null) {
    if (!status.hasAllocations) {
      host.showMessage(
          'No region index yet — the main agent will design the layout.\n');
      return CmdRun(_proposalPrompt);
    }
    final ok = await confirm('Summarize the ${status.totalDirs} proposed '
        'regions? [y/N] ');
    if (!ok) return const CmdHandled();
    host.showMessage('Indexing ${status.totalDirs} '
        '${status.totalDirs == 1 ? 'region' : 'regions'}…\n');
    final r = await summaryIndex.refresh();
    _postIndexRefresh(host, r, verb: 'Indexed');
    return const CmdHandled();
  }

  // First run (empty manifest) or every dir changed since the last index.
  if (status.firstRun || status.allStale) {
    host.showMessage(
      'Indexing ${status.totalDirs} '
      '${status.totalDirs == 1 ? 'directory' : 'directories'}…\n');
    final r = await summaryIndex.refresh();
    _postIndexRefresh(host, r, verb: 'Indexed');
    return const CmdHandled();
  }

  // Nothing stale → up to date. Confirm before re-running everything.
  if (status.staleCount == 0) {
    host.showMessage(
      'Index is up to date (${status.totalDirs} dirs'
      '${status.headSha != null ? ' @ ${_shortSha(status.headSha!)}' : ''}).\n');
    if (confirm == null) {
      // Headless: no interactive input, so a re-run can't be confirmed.
      return const CmdHandled();
    }
    final ok = await confirm(
      'Re-run all ${status.totalDirs} summaries anyway? [y/N] ');
    if (!ok) return const CmdHandled();
    host.showMessage('Re-indexing ${status.totalDirs} dirs…\n');
    final r = await summaryIndex.refresh(repartition: true);
    _postIndexRefresh(host, r, verb: 'Re-indexed');
    return const CmdHandled();
  }

  // Partly stale: re-run just the stale dirs.
  host.showMessage(
    '${status.staleCount}/${status.totalDirs} dirs stale: '
    '${status.staleDirs.join(', ')}. Refreshing…\n');
  final r = await summaryIndex.refresh();
  _postIndexRefresh(host, r, verb: 'Refreshed');
  return const CmdHandled();
}

void _postIndexRefresh(HostInterface host, SummaryIndexResult r,
    {required String verb}) {
  final n = r.regenerated;
  final parts = <String>[
    '$verb $n ${n == 1 ? 'directory' : 'directories'}',
  ];
  if (r.deletedDirs.isNotEmpty) {
    parts.add('removed ${r.deletedDirs.length}');
  }
  if (r.status.headSha != null) {
    parts.add('@ ${_shortSha(r.status.headSha!)}');
  }
  host.showMessage('${parts.join(', ')}.\n',
      style: HostMessageStyle.success);
}

String _shortSha(String sha) => sha.length >= 7 ? sha.substring(0, 7) : sha;
