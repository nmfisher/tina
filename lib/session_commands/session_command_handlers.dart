import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import '../self_update/release_checker.dart';
import '../self_update/updater.dart';
import '../version.g.dart';
import '../summaries/summary_index.dart';
import '../pipeline/pipeline_commands.dart';
import '../tmux/tmux_support.dart';
import 'command_context.dart';
import 'session_export.dart';

part 'session_command_registry.dart';

/// The slash-command handlers, lifted out of [SessionController] so they can be
/// read and tested in isolation. Operates purely through a [CommandContext] —
/// no input loop, no host of its own. [dispatch] is the entry point the
/// controller calls each input line; it echoes the command, runs any registered
/// hook, and switches on the command word exactly as the controller used to.
class SessionCommandHandlers {
  final CommandContext ctx;
  SessionCommandHandlers(this.ctx, {this.releaseCheckerFactory});

  /// Seam for tests: builds the [ReleaseChecker] `/update` uses. Production
  /// calls leave it null and a real checker (with [Platform.environment])
  /// is constructed per invocation and closed afterwards.
  final ReleaseChecker? Function(Map<String, String> env)?
      releaseCheckerFactory;

  /// Every recognized slash command, in display order — derived from the
  /// command registry ([registry], via [SessionCommandRegistry.allNames]),
  /// which remains the single source of truth for [dispatch] and the `/`
  /// command-completion palette ([CommandCompletionProvider]). Kept as a
  /// getter (not deleted) because existing tests and callers name it; the
  /// compiler-checked derivation cannot drift from the registry.
  static List<String> get allCommands => registry.allNames;

  /// The ordered command table every command surface dispatches, completes,
  /// and renders help from.
  static final SessionCommandRegistry registry =
      SessionCommandRegistry(_kSessionCommandEntries);

  Future<CmdResult> dispatch(String trimmed) async {
    final word = trimmed.split(RegExp(r'\s+')).first;
    final entry = registry.lookup(word);
    if (entry == null) {
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
    // Keyed by the typed word, so hooks fire for aliases too (`/quit` fires
    // the `/quit` hook, not the `/exit` one).
    final hook = ctx.commandHooks[word];
    if (hook != null) {
      await hook();
    }

    return entry.handler(this, trimmed);
  }

  /// `/spend` — the session's token usage (all agents + sub-agents +
  /// workflows), the global cap, and the RPM throttle.
  Future<void> _handleSpend() async {
    final ledger = ctx.spendLedger;
    if (ledger == null) {
      ctx.active.host.showMessage(
          'no spend ledger available (headless run?)\n',
          style: HostMessageStyle.warning);
      return;
    }
    final buf = StringBuffer(
        'Session spend: ${_formatCount(ledger.totalTokens)} tokens '
        '(input + output)');
    if (ledger.seededTokens > 0) {
      buf.write(' — ${_formatCount(ledger.seededTokens)} restored from a '
          'previous run');
    }
    buf.writeln();
    // #46: failed-attempt spend is booked distinctly — measured (the error
    // carried provider-reported usage) or estimated (body-size floor) — and
    // counts toward the cap arithmetic, so show it separately here rather
    // than folding it into the measured number.
    final est = ledger.totalEstimatedTokens;
    if (est > 0) {
      buf.writeln('Failed-attempt bookings: '
          '${_formatCount(est)} estimated tokens '
          '(re-sent bodies the retry ladders swallowed — the measured '
          'error-body usage rides in the total above); combined total '
          '${_formatCount(ledger.grandTotalTokens)}');
    }
    final cap = ledger.cap;
    if (cap != null) {
      buf.writeln('Global cap: ${_formatCount(cap)} · '
          '${ledger.tripped ? 'TRIPPED — all agents are paused' : 'not tripped'}');
    }
    if (ledger.rpm > 0) {
      buf.writeln('Requests/min cap: ${ledger.rpm}');
    }
    ctx.active.host.showMessage(buf.toString(), style: HostMessageStyle.dim);
  }

  /// `/update` — check GitHub for a newer release and, after a y/n confirm,
  /// download + swap the bundle in place (restart finishes it). Headless has
  /// no confirm; it just reports the latest and links the release.
  Future<void> _handleUpdate() async {
    final host = ctx.active.host;
    final injected = releaseCheckerFactory?.call(Platform.environment);
    final checker = injected ?? ReleaseChecker(env: Platform.environment);
    try {
      host.showMessage('checking for updates…\n', style: HostMessageStyle.dim);
      final release = await checker.fetchLatest();
      if (release == null) {
        host.showMessage('could not reach GitHub for the release check.\n',
            style: HostMessageStyle.warning);
        return;
      }
      if (!isNewer(release.tag)) {
        host.showMessage(
            'tina $tinaVersion is up to date (latest: ${release.tag}).\n',
            style: HostMessageStyle.dim);
        return;
      }
      host.showMessage(
          'tina ${release.tag} is available.\n', style: HostMessageStyle.dim);
      final confirm = ctx.confirm;
      if (confirm == null) {
        host.showMessage(
            'headless run — download it from ${release.releaseUrl}\n',
            style: HostMessageStyle.dim);
        return;
      }
      if (!await confirm('Download and install tina ${release.tag}?')) {
        return;
      }
      final result = await installRelease(release,
          notice: (line) =>
              host.showMessage('$line\n', style: HostMessageStyle.dim));
      switch (result) {
        case UpdateResult.success:
          host.showMessage('updated — restart tina to finish.\n',
              style: HostMessageStyle.dim);
        case UpdateResult.unsupported:
          host.showMessage(
              'no release asset for this platform — '
              'see ${ReleaseChecker.releasesPageUrl}\n',
              style: HostMessageStyle.dim);
        case UpdateResult.manualRequired:
          host.showMessage(
              'this install can\'t be replaced in place (running from '
              'source, or a read-only location).\n'
              'Download the new bundle from ${release.releaseUrl} and replace '
              'this installation manually.\n',
              style: HostMessageStyle.dim);
        case UpdateResult.failed:
          break; // installRelease already noticed the reason
      }
    } finally {
      // An injected checker belongs to the test; only close one we made.
      if (injected == null) checker.close();
    }
  }

  String _formatCount(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
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
      'hetzner',
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

  /// `/detach` — leave the terminal behind, keep the agent running. Only
  /// meaningful under tmux, where the tina process survives the detach. The
  /// TUI coordinator wires [ctx.detachTmux] and owns ALL the messaging (the
  /// "detached"/"reattach" notice, the failure notice, and the "not running in
  /// tmux" hint) so `/detach` and the Alt+D keybind — which calls the same
  /// seam directly — read identically. When nothing is wired (headless) there's
  /// no terminal to detach from, so we print just the one-line hint.
  Future<void> _handleDetach() async {
    final detach = ctx.detachTmux;
    if (detach == null) {
      ctx.active.host.showMessage('${TmuxSupport.notInTmuxHint}\n',
          style: HostMessageStyle.dim);
      return;
    }
    await detach();
  }

  void _printHelp() {
    // Rendered structurally from the command registry — same bytes as the
    // pre-registry literal (golden-tested in
    // test/session_commands/session_command_registry_test.dart).
    ctx.active.host.showMessage(registry.renderHelp());
  }

  /// `/permissions` — show rules; `/permissions <ask|read-all|allow-edits|
  /// auto>` switches the permission mode at runtime. The switch is wired by
  /// the TUI (base policy + every live conversation); headless reports it's
  /// unavailable.
  Future<void> _handlePermissions(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      _printPermissions();
      return;
    }
    final mode = switch (parts[1]) {
      'ask' => PermissionMode.ask,
      'read-all' || 'read_all' => PermissionMode.readAll,
      'allow-edits' || 'allow_edits' => PermissionMode.allowEdits,
      'auto' => PermissionMode.auto,
      _ => null,
    };
    if (mode == null) {
      ctx.active.host.showMessage(
          'unknown mode "${parts[1]}" — use ask, read-all, allow-edits, '
          'or auto\n',
          style: HostMessageStyle.error);
      return;
    }
    final switcher = ctx.setPermissionMode;
    if (switcher == null) {
      ctx.active.host.showMessage(
          'runtime mode switch unavailable here — start with '
          '--permission-mode ${parts[1]}\n',
          style: HostMessageStyle.warning);
      return;
    }
    switcher(mode);
    ctx.active.host.showMessage('permission mode: ${parts[1]}\n');
  }

  void _printPermissions() {
    final policy = ctx.active.policy;
    ctx.active.host
        .showMessage('mode: ${policy.mode.name}\n', style: HostMessageStyle.dim);
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
    // In the TUI, /sessions opens the session picker (same overlay as Alt+S):
    // select an entry to switch the live session or resume a saved one into
    // this process. Headless (no picker wired) keeps the printed list — the
    // resume ids are still needed there for `tina --resume <id>`.
    final open = ctx.openSessionPicker;
    if (open != null) {
      await open();
      return;
    }
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

  /// `/save <path>` — export the ACTIVE session as a markdown transcript.
  ///
  /// Reads the session back from the store (manifest + every conversation)
  /// and writes the rendered transcript to [path]. Refuses to overwrite an
  /// existing file and never creates directories — the path must point at an
  /// existing folder. All failures are reported, never thrown.
  Future<void> _handleSave(String line) async {
    final host = ctx.active.host;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length != 2 || parts[1].isEmpty) {
      host.showMessage(
          'usage: /save <path> — export this session as markdown\n',
          style: HostMessageStyle.warning);
      return;
    }
    final recorder = ctx.active.recorder;
    final store = recorder?.store ?? ctx.sessionStore;
    final sessionId = recorder?.sessionId;
    if (store == null || sessionId == null) {
      host.showMessage(
          'session persistence is disabled — nothing to save\n',
          style: HostMessageStyle.error);
      return;
    }

    // Expand a leading `~` the same way the platform paths do
    // (HOME on POSIX, USERPROFILE on Windows).
    var target = parts[1];
    if (target == '~' || target.startsWith('~/')) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        host.showMessage('cannot expand ~ (no HOME set)\n',
            style: HostMessageStyle.error);
        return;
      }
      target = target == '~' ? home : p.join(home, target.substring(2));
    }
    if (!p.isAbsolute(target)) {
      target = p.join(Directory.current.path, target);
    }
    final parentPath = p.dirname(target);
    final parent = Directory(parentPath);
    if (!parent.existsSync()) {
      host.showMessage(
          'directory does not exist: $parentPath '
          '(create it first; /save does not mkdir)\n',
          style: HostMessageStyle.error);
      return;
    }
    if (File(target).existsSync() || Directory(target).existsSync()) {
      host.showMessage('refusing to overwrite: $target\n',
          style: HostMessageStyle.error);
      return;
    }

    final SessionManifest manifest;
    try {
      manifest = await store.loadSession(sessionId);
    } catch (e) {
      host.showMessage('failed to load session $sessionId: $e\n',
          style: HostMessageStyle.error);
      return;
    }
    final byConversation = <String, List<Message>>{};
    var totalMessages = 0;
    for (final conv in manifest.conversations) {
      try {
        final messages = await store.loadConversation(sessionId, conv.id);
        totalMessages += messages.length;
        byConversation[conv.id] = messages;
      } catch (e) {
        host.showMessage(
            'skipping conversation ${conv.id} (unreadable: $e)\n',
            style: HostMessageStyle.warning);
      }
    }
    if (byConversation.isEmpty && manifest.conversations.isNotEmpty) {
      host.showMessage(
          'nothing saved — none of this session\'s conversations could be '
          'read from the store\n',
          style: HostMessageStyle.error);
      return;
    }
    final transcript = renderSessionTranscript(manifest, byConversation);
    try {
      await File(target).writeAsString(transcript, flush: true);
    } catch (e) {
      host.showMessage('failed to write $target: $e\n',
          style: HostMessageStyle.error);
      return;
    }
    host.showMessage(
        'saved $totalMessages messages across ${byConversation.length} '
        'conversations (${transcript.length} bytes) → $target\n',
        style: HostMessageStyle.dim);
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
    // A tripped spend cap pauses every agent — /index must not be the one
    // loophole (the fleet runs on its own ephemeral ledger, merged only after
    // the run, so the cap itself can't stop it). Headless has no ledger and
    // is unaffected.
    if (ctx.spendLedger?.tripped == true) {
      ctx.active.host.showMessage(
          'Token spend ceiling already tripped — /index skipped. '
          'Raise the cap (or /spend to review) first.\n',
          style: HostMessageStyle.error);
      return const CmdHandled();
    }
    // The TUI runs the fleet in the background (input stays live, Esc-Esc
    // cancels); headless has no wiring and runs it inline, blocking to
    // completion.
    final bg = ctx.runBackgroundIndex;
    final env = ctx.runBackgroundEnvironment;
    return runIndexDance(
      host: ctx.active.host,
      summaryIndex: idx,
      confirm: ctx.confirm,
      refreshFn: bg == null
          ? null
          : ({bool repartition = false, List<String>? dirs}) {
              bg(ctx.active, dirs, repartition: repartition);
              return Future<SummaryIndexResult?>.value();
            },
      runEnvironment: env == null ? null : () => env(ctx.active),
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

/// How [runIndexDance] launches the fleet. Null = run it inline via
/// [SummaryIndex.refresh] and await it (headless). Non-null = hand it off
/// (the TUI's background task), returning immediately — the task posts its
/// own start/completion notices, so the dance skips its own.
typedef IndexRefreshFn = Future<SummaryIndexResult?> Function({
  bool repartition,
  List<String>? dirs,
});

/// The `/index` staleness dance, factored out of [SessionCommandHandlers] so the
/// headless runner (`bin/tina.dart --non-interactive -p /index`) can reuse it
/// without a [SessionController]: probe staleness (pure git, no LLM), then
/// branch — index all on a first run / when everything is stale; re-run only the
/// stale dirs when partly stale; report up-to-date and confirm (when [confirm]
/// is wired, i.e. the TUI) before a full re-run. The fleet runs via
/// [SummaryIndex.refresh] (inline, awaited) or is handed to [refreshFn] (the
/// TUI's background task); notices go to [host].
Future<CmdResult> runIndexDance({
  required HostInterface host,
  required SummaryIndex summaryIndex,
  Future<bool> Function(String prompt)? confirm,
  IndexRefreshFn? refreshFn,
  Future<void> Function()? runEnvironment,
}) async {
  // Run the fleet and report, or hand it off. [startMsg] is posted only in
  // inline mode (the background task announces itself); [verb] labels the
  // inline completion report.
  Future<void> refreshAndReport({
    required String startMsg,
    required String verb,
    bool repartition = false,
    List<String>? dirs,
  }) async {
    if (refreshFn != null) {
      await refreshFn(repartition: repartition, dirs: dirs);
      return;
    }
    if (startMsg.isNotEmpty) host.showMessage(startMsg);
    final r = await summaryIndex.refresh(repartition: repartition, dirs: dirs);
    _postIndexRefresh(host, r, verb: verb);
  }

  final status = await summaryIndex.status();

  // The environment region: the dance flags, the environment agent acts
  // (docs/proposals/environment_agent.md, "Region integration"). Independent
  // of the dir branches below, so it runs whichever way they go. The TUI hands
  // it to its background task; headless only reports (an unattended run must
  // not install dependencies or touch git config).
  if (status.envStale) {
    if (runEnvironment != null) {
      host.showMessage(status.envFirstLoad
          ? 'No environment record yet — running the environment agent in the '
              'background (Esc-Esc to cancel)…\n'
          : 'Environment record is stale (${status.envStaleReason}) — running '
              'the environment agent in the background…\n');
      await runEnvironment();
    } else {
      host.showMessage(
          'Environment record is ${status.envFirstLoad ? 'missing' : 'stale'}'
          '${status.envStaleReason == null ? '' : ' (${status.envStaleReason})'}'
          ' — refresh it from an interactive session.\n');
    }
  }

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
      // Escape hatch: a proposal turn already ran and still no allocations
      // (the agent allocated nothing, or every region was since deleted).
      // Offering another paid proposal turn would loop forever — fall back to
      // confirming the default partition instead.
      if (summaryIndex.proposalShown) {
        final fallback = await confirm(
            'The proposal turn ran but allocated no regions. '
            'Index the default partition instead? [y/N] ');
        if (!fallback) return const CmdHandled();
        await refreshAndReport(
          startMsg: 'Indexing ${status.totalDirs} '
              '${status.totalDirs == 1 ? 'directory' : 'directories'}…\n',
          verb: 'Indexed',
          dirs: status.staleDirs,
        );
        return const CmdHandled();
      }
      host.showMessage(
          'No region index yet — the main agent will design the layout.\n');
      summaryIndex.markProposalShown();
      return CmdRun(_proposalPrompt);
    }
    final ok = await confirm('Summarize the ${status.totalDirs} proposed '
        'regions? [y/N] ');
    if (!ok) return const CmdHandled();
    await refreshAndReport(
      startMsg: 'Indexing ${status.totalDirs} '
          '${status.totalDirs == 1 ? 'region' : 'regions'}…\n',
      verb: 'Indexed',
      dirs: status.staleDirs,
    );
    return const CmdHandled();
  }

  // First run (empty manifest) or every dir changed since the last index.
  if (status.firstRun || status.allStale) {
    await refreshAndReport(
      startMsg: 'Indexing ${status.totalDirs} '
          '${status.totalDirs == 1 ? 'directory' : 'directories'}…\n',
      verb: 'Indexed',
      dirs: status.staleDirs,
    );
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
    await refreshAndReport(
      startMsg: 'Re-indexing ${status.totalDirs} dirs…\n',
      verb: 'Re-indexed',
      repartition: true,
    );
    return const CmdHandled();
  }

  // Partly stale: re-run just the stale dirs. The stale-dirs report posts in
  // both modes (it explains WHAT the background run is doing).
  host.showMessage(
    '${status.staleCount}/${status.totalDirs} dirs stale: '
    '${status.staleDirs.join(', ')}. Refreshing…\n');
  await refreshAndReport(
    startMsg: '',
    verb: 'Refreshed',
    dirs: status.staleDirs,
  );
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
