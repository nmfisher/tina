part of 'session_command_handlers.dart';

class UsageCommands {
  final UsageCapabilities ctx;
  UsageCommands(this.ctx);

  /// `/spend` — the session's token usage (all agents + sub-agents +
  /// workflows), the global cap, and the RPM throttle.
  Future<void> _handleSpend() async {
    final ledger = ctx.spendLedger;
    if (ledger == null) {
      ctx.active.host.showMessage(
        'no spend ledger available (headless run?)\n',
        style: HostMessageStyle.warning,
      );
      return;
    }
    final buf = StringBuffer(
      'Session spend: ${_formatCount(ledger.totalTokens)} tokens '
      '(input + output)',
    );
    if (ledger.seededTokens > 0) {
      buf.write(
        ' — ${_formatCount(ledger.seededTokens)} restored from a '
        'previous run',
      );
    }
    buf.writeln();
    // #46: failed-attempt spend is booked distinctly — measured (the error
    // carried provider-reported usage) or estimated (body-size floor) — and
    // counts toward the cap arithmetic, so show it separately here rather
    // than folding it into the measured number.
    final est = ledger.totalEstimatedTokens;
    if (est > 0) {
      buf.writeln(
        'Failed-attempt bookings: '
        '${_formatCount(est)} estimated tokens '
        '(re-sent bodies the retry ladders swallowed — the measured '
        'error-body usage rides in the total above); combined total '
        '${_formatCount(ledger.grandTotalTokens)}',
      );
    }
    final cap = ledger.cap;
    if (cap != null) {
      buf.writeln(
        'Global cap: ${_formatCount(cap)} · '
        '${ledger.tripped ? 'TRIPPED — all agents are paused' : 'not tripped'}',
      );
    }
    if (ledger.rpm > 0) {
      buf.writeln('Requests/min cap: ${ledger.rpm}');
    }
    ctx.active.host.showMessage(buf.toString(), style: HostMessageStyle.dim);
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
}

class UpdateCommands {
  final UpdateCapabilities ctx;
  final ReleaseChecker? Function(Map<String, String> env)?
  releaseCheckerFactory;

  /// Test seam for the download/verify/extract stage: production leaves it
  /// null and the handler calls [prepareUpdate] directly.
  final Future<UpdatePrepareOutcome> Function(
    ReleaseInfo release,
    void Function(String line) notice,
  )? prepareOverride;
  UpdateCommands(this.ctx,
      {this.releaseCheckerFactory, this.prepareOverride});

  /// `/update` — check GitHub for a newer release, download + verify it,
  /// then ask y/n before swapping the bundle in place (restart finishes it).
  /// The confirm comes after the download, not before: a declined prompt
  /// costs nothing and an accepted one starts at the swap. Headless has no
  /// confirm; it just reports the latest and links the release.
  Future<void> _handleUpdate() async {
    final host = ctx.active.host;
    final injected = releaseCheckerFactory?.call(Platform.environment);
    final checker = injected ?? ReleaseChecker(env: Platform.environment);
    try {
      host.showMessage('checking for updates…\n', style: HostMessageStyle.dim);
      final release = await checker.fetchLatest();
      if (release == null) {
        host.showMessage(
          'could not reach GitHub for the release check.\n',
          style: HostMessageStyle.warning,
        );
        return;
      }
      if (!isNewer(release.tag)) {
        host.showMessage(
          'tina $tinaVersion is up to date (latest: ${release.tag}).\n',
          style: HostMessageStyle.dim,
        );
        return;
      }
      host.showMessage(
        'tina ${release.tag} is available.\n',
        style: HostMessageStyle.dim,
      );
      final confirm = ctx.confirm;
      if (confirm == null) {
        host.showMessage(
          'headless run — download it from ${release.releaseUrl}\n',
          style: HostMessageStyle.dim,
        );
        return;
      }
      void notice(String line) =>
          host.showMessage('$line\n', style: HostMessageStyle.dim);
      // Download + verify + extract first; swap only after the user says so.
      final prepared = await (prepareOverride?.call(release, notice) ??
          prepareUpdate(release, notice: notice));
      switch (prepared) {
        case UpdatePrepareUnsupported():
          host.showMessage(
            'no release asset for this platform — '
            'see ${ReleaseChecker.releasesPageUrl}\n',
            style: HostMessageStyle.dim,
          );
          return;
        case UpdatePrepareManualRequired():
          host.showMessage(
            'this install can\'t be replaced in place (running from '
            'source, a read-only location, or a directory tina doesn\'t '
            'exclusively own — the updater only swaps a directory holding '
            'nothing but tina).\n'
            'Re-run the latest install.sh to install a private bundle '
            'with a launcher on PATH, or download the bundle from '
            '${release.releaseUrl}.\n',
            style: HostMessageStyle.dim,
          );
          return;
        case UpdatePrepareFailure():
          return; // prepareUpdate already noticed the reason
        case UpdatePrepareReady():
          break;
      }
      if (!await confirm(
        'tina ${prepared.update.tag} downloaded and verified — '
        'install it now?',
      )) {
        prepared.update.discard();
        return;
      }
      final result = await prepared.update.install(notice: notice);
      switch (result) {
        case UpdateResult.success:
          host.showMessage(
            'updated — restart tina to finish.\n',
            style: HostMessageStyle.dim,
          );
        case UpdateResult.unsupported:
        case UpdateResult.manualRequired:
          break; // impossible after a ready prepare; nothing new to say
        case UpdateResult.failed:
          break; // install already noticed the reason
      }
    } finally {
      // An injected checker belongs to the test; only close one we made.
      if (injected == null) checker.close();
    }
  }
}

class FrontendCommands {
  final FrontendCapabilities ctx;
  FrontendCommands(this.ctx);

  /// `/blocks` — list the transcript's foldable blocks, numbered, with what
  /// each one would reveal.
  Future<void> _handleBlocks() async {
    final fold = ctx.foldTranscript;
    if (fold == null) {
      _noTranscript();
      return;
    }
    await fold('list', '');
  }

  /// `/show <n|all>` and `/hide <n|all>` — open or close a block in place.
  Future<void> _handleFold(String trimmed, {required bool show}) async {
    final fold = ctx.foldTranscript;
    if (fold == null) {
      _noTranscript();
      return;
    }
    final argument = trimmed.split(RegExp(r'\s+')).skip(1).join(' ');
    if (argument.isEmpty) {
      ctx.active.host.showMessage(
        'usage: /${show ? 'show' : 'hide'} <n|all> — '
        '${show ? 'reveal' : 'collapse'} a block from /blocks.\n',
        style: HostMessageStyle.warning,
      );
      return;
    }
    await fold(show ? 'show' : 'hide', argument);
  }

  void _noTranscript() => ctx.active.host.showMessage(
    'this session has no transcript to fold.\n',
    style: HostMessageStyle.warning,
  );

  Future<void> _handleSettings() async {
    final open = ctx.openSettings;
    if (open == null) {
      ctx.active.host.showMessage(
        '/settings needs the interactive TUI; edit ~/.tina/config '
        '(or `tina --init-config`) instead.\n',
        style: HostMessageStyle.warning,
      );
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
        style: HostMessageStyle.warning,
      );
      return;
    }
    await open();
  }

  Future<void> _handleSpawn() async {
    final open = ctx.openSpawn;
    if (open == null) {
      ctx.active.host.showMessage(
        '/spawn needs the interactive TUI to show the model picker.\n',
        style: HostMessageStyle.warning,
      );
      return;
    }
    await open();
  }

  Future<void> _handleBranch() async {
    final open = ctx.openBranch;
    if (open == null) {
      ctx.active.host.showMessage(
        '/branch needs the interactive TUI to show the model + role pickers.\n',
        style: HostMessageStyle.warning,
      );
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
        style: HostMessageStyle.warning,
      );
      return;
    }
    await open(parts[1]);
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
      ctx.active.host.showMessage(
        '${TmuxSupport.notInTmuxHint}\n',
        style: HostMessageStyle.dim,
      );
      return;
    }
    await detach();
  }

  Future<void> _handleModel(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length > 1) {
      ctx.active.host.showMessage(
        'usage: /model  (opens the picker)\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    final open = ctx.openModelPicker;
    if (open == null) {
      ctx.active.host.showMessage('model: ${ctx.active.provider.model}\n');
      return;
    }
    await open();
  }
}

class SessionsCommands {
  final SessionsCapabilities ctx;
  SessionsCommands(this.ctx);
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
          ctx.active.host.showMessage(
            'no unique session matching "${parts[2]}"\n',
            style: HostMessageStyle.error,
          );
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
            'usage: /session rename <id> <new-label>\n',
          );
          return;
        }
        _renameSession(parts[2], parts.sublist(3).join(' '));
      default:
        ctx.active.host.showMessage(
          'usage: /session '
          '[list | new [provider:model] | switch <id> | close <id> | '
          'rename <id> <label>]\n',
        );
    }
  }

  void _renameSession(String token, String newLabel) {
    if (newLabel.isEmpty) {
      ctx.active.host.showMessage(
        'label cannot be empty\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    final id = _resolveLiveId(token);
    if (id == null) {
      ctx.active.host.showMessage(
        'no unique session matching "$token"\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    ctx.sessionManager.all.firstWhere((x) => x.id == id).label = newLabel;
    ctx.active.host.showMessage(
      '(renamed ${_shortId(id)} to "$newLabel")\n',
      style: HostMessageStyle.dim,
    );
    ctx.onSessionsChanged?.call();
  }

  void _closeSession(String token) {
    final id = _resolveLiveId(token);
    if (id == null) {
      ctx.active.host.showMessage(
        'no unique session matching "$token"\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    if (id == ctx.sessionManager.activeId) {
      ctx.active.host.showMessage(
        'cannot close the active session — switch away first\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    final s = ctx.sessionManager.all.firstWhere((x) => x.id == id);
    if (s.isRunning) {
      ctx.active.host.showMessage(
        'session is running — switch to it and press ESC first\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    ctx.sessionManager.close(id);
    ctx.active.host.showMessage(
      '(closed ${_shortId(id)})\n',
      style: HostMessageStyle.dim,
    );
    ctx.onSessionsChanged?.call();
  }

  void _printLiveSessions() {
    for (final s in ctx.sessionManager.listSessions()) {
      final marker = s.isActive ? '* ' : '  ';
      final running = s.isRunning ? ' (running)' : '';
      ctx.active.host.showMessage('$marker${s.id}  ');
      ctx.active.host.showMessage(
        '${s.label}  ${s.msgCount}msg$running\n',
        style: HostMessageStyle.dim,
      );
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
      ctx.active.host.showMessage(
        '(no session store available)\n',
        style: HostMessageStyle.dim,
      );
      return;
    }
    final List<SessionMeta> sessions;
    try {
      sessions = await ctx.sessionStore!.listSessions();
    } catch (e) {
      ctx.active.host.showMessage(
        'failed to list sessions: $e\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    if (sessions.isEmpty) {
      ctx.active.host.showMessage(
        '(no saved sessions)\n',
        style: HostMessageStyle.dim,
      );
      return;
    }
    final current = ctx.active.recorder?.sessionId;
    for (final s in sessions) {
      final marker = s.id == current ? '* ' : '  ';
      final stamp = _shortStamp(s.updatedAt);
      ctx.active.host.showMessage(
        '$marker${s.id}  $stamp  ${s.messageCount}msg  ',
      );
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
        style: HostMessageStyle.warning,
      );
      return;
    }
    final recorder = ctx.active.recorder;
    final store = recorder?.store ?? ctx.sessionStore;
    final sessionId = recorder?.sessionId;
    if (store == null || sessionId == null) {
      host.showMessage(
        'session persistence is disabled — nothing to save\n',
        style: HostMessageStyle.error,
      );
      return;
    }

    // Expand a leading `~` the same way the platform paths do
    // (HOME on POSIX, USERPROFILE on Windows).
    var target = parts[1];
    if (target == '~' || target.startsWith('~/')) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        host.showMessage(
          'cannot expand ~ (no HOME set)\n',
          style: HostMessageStyle.error,
        );
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
        style: HostMessageStyle.error,
      );
      return;
    }
    if (File(target).existsSync() || Directory(target).existsSync()) {
      host.showMessage(
        'refusing to overwrite: $target\n',
        style: HostMessageStyle.error,
      );
      return;
    }

    final SessionManifest manifest;
    try {
      manifest = await store.loadSession(sessionId);
    } catch (e) {
      host.showMessage(
        'failed to load session $sessionId: $e\n',
        style: HostMessageStyle.error,
      );
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
          style: HostMessageStyle.warning,
        );
      }
    }
    if (byConversation.isEmpty && manifest.conversations.isNotEmpty) {
      host.showMessage(
        'nothing saved — none of this session\'s conversations could be '
        'read from the store\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    final transcript = renderSessionTranscript(manifest, byConversation);
    try {
      await File(target).writeAsString(transcript, flush: true);
    } catch (e) {
      host.showMessage(
        'failed to write $target: $e\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    host.showMessage(
      'saved $totalMessages messages across ${byConversation.length} '
      'conversations (${transcript.length} bytes) → $target\n',
      style: HostMessageStyle.dim,
    );
  }

  static String _shortStamp(DateTime t) {
    final l = t.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${pad(l.month)}-${pad(l.day)} '
        '${pad(l.hour)}:${pad(l.minute)}';
  }
}

class HistoryCommands {
  final HistoryCapabilities ctx;
  HistoryCommands(this.ctx);
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
    // Through the driver: a scripted (or otherwise agent-less) conversation
    // has no agent to compact — the driver owns this operation.
    final activity = RunActivity(s.host);
    try {
      await s.driver.compact(s.history, cancelSignal: ctx.commandCancelSignal);
    } finally {
      activity.complete();
    }
    final rec = s.recorder;
    if (rec != null) {
      try {
        await rec.replace(s.history);
      } catch (e) {
        s.host.showMessage(
          'session write failed: $e\n',
          style: HostMessageStyle.error,
        );
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
        style: HostMessageStyle.dim,
      );
      return;
    }
    final arg = parts[1].toLowerCase();
    if (arg == 'off' || arg == '0') {
      ctx.autoCompactThreshold = 0;
      ctx.active.host.showMessage(
        'auto-compact: off\n',
        style: HostMessageStyle.dim,
      );
      return;
    }
    final n = int.tryParse(arg);
    if (n == null || n < 0) {
      ctx.active.host.showMessage(
        'usage: /auto-compact [<number>|off]  (0 disables)\n',
        style: HostMessageStyle.error,
      );
      return;
    }
    ctx.autoCompactThreshold = n;
    ctx.active.host.showMessage(
      'auto-compact: $n tokens (applies from the next turn)\n',
      style: HostMessageStyle.dim,
    );
  }
}

class PermissionsCommands {
  final PermissionsCapabilities ctx;
  PermissionsCommands(this.ctx);

  /// `/permissions` — show rules; `/permissions <ask|read-all|allow-edits|
  /// auto>` switches the permission mode at runtime; `/permissions revoke
  /// [tool[:pattern]|all]` forgets what an approval remembered. The mode switch
  /// is wired by the TUI (base policy + every live conversation); headless
  /// reports it's unavailable.
  Future<void> _handlePermissions(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      _printPermissions();
      return;
    }
    if (parts[1] == 'revoke' || parts[1] == 'forget') {
      // The target keeps its spaces: a bash command is the pattern, and
      // `revoke bash:git status` must name the whole thing.
      _revokePermission(parts.length > 2 ? parts.sublist(2).join(' ') : null);
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
        style: HostMessageStyle.error,
      );
      return;
    }
    final switcher = ctx.setPermissionMode;
    if (switcher == null) {
      ctx.active.host.showMessage(
        'runtime mode switch unavailable here — start with '
        '--permission-mode ${parts[1]}\n',
        style: HostMessageStyle.warning,
      );
      return;
    }
    switcher(mode);
    ctx.active.host.showMessage('permission mode: ${parts[1]}\n');
  }

  /// `/permissions revoke [target]` — drop remembered approvals. No target (or
  /// `all`) clears every one; `tool` clears that tool's; `tool:pattern` clears
  /// exactly that rule. Configured rules are untouched: this forgets answers
  /// given at a prompt, it does not edit configuration.
  void _revokePermission(String? target) {
    final policy = ctx.active.policy;
    final all = target == null || target == 'all';
    final colon = target?.indexOf(':') ?? -1;
    final removed = all
        ? policy.forget()
        : policy.forget(
            tool: colon < 0 ? target : target.substring(0, colon),
            pattern: colon < 0 ? null : target.substring(colon + 1),
          );
    ctx.active.host.showMessage(
      removed == 0
          ? 'nothing remembered for ${target ?? 'this conversation'}\n'
          : 'revoked $removed remembered '
                '${removed == 1 ? 'approval' : 'approvals'}\n',
      style: removed == 0 ? HostMessageStyle.dim : HostMessageStyle.normal,
    );
  }

  void _printPermissions() {
    final policy = ctx.active.policy;
    ctx.active.host.showMessage(
      'mode: ${policy.mode.name}\n',
      style: HostMessageStyle.dim,
    );
    if (policy.allowAllByDefault) {
      ctx.active.host.showMessage(
        'defaults: every tool allowed (--yolo; explicit --deny still applies)\n',
        style: HostMessageStyle.dim,
      );
    } else {
      ctx.active.host.showMessage('defaults:\n');
      final keys = policy.defaults.keys.toList()..sort();
      for (final k in keys) {
        ctx.active.host.showMessage(
          '  $k: ${policy.defaults[k]!.name}\n',
          style: HostMessageStyle.dim,
        );
      }
    }
    if (policy.staticRules.isNotEmpty) {
      ctx.active.host.showMessage('cli rules:\n');
      for (final r in policy.staticRules) {
        ctx.active.host.showMessage('  $r\n', style: HostMessageStyle.dim);
      }
    }
    if (policy.sessionGrants.isNotEmpty) {
      // Scope and who answered ride along: an approval the classifier made for
      // itself must not read like one you gave.
      ctx.active.host.showMessage(
        'remembered approvals (/permissions revoke to forget):\n',
      );
      for (final grant in policy.sessionGrants) {
        ctx.active.host.showMessage('  $grant\n', style: HostMessageStyle.dim);
      }
    } else if (policy.staticRules.isEmpty) {
      ctx.active.host.showMessage(
        '(no rules; defaults only)\n',
        style: HostMessageStyle.dim,
      );
    }
  }
}

class IndexCommands {
  final IndexCapabilities ctx;
  IndexCommands(this.ctx);

  /// Classify languages, frameworks and tooling, merging findings upward.
  Future<CmdResult> _handleIndex(String input) async {
    final parts = input.trim().split(RegExp(r'\s+'));
    IndexOptions options;
    try {
      options = IndexOptions.parse(parts.skip(1).join(' '));
    } on ArgumentError {
      ctx.active.host.showMessage('${IndexOptions.usage}\n');
      return const CmdHandled();
    }
    final conversation = ctx.active;
    // Classification uses the same session spending limit as other agent work.
    if (options.method == LanguageMethod.jev && options.mode != 'status' && options.mode != 'view' && ctx.spendLedger?.tripped == true) {
      conversation.host.showMessage(
        'Token spend ceiling already tripped — /index skipped. '
        'Raise the cap (or /spend to review) first.\n',
        style: HostMessageStyle.error,
      );
      return const CmdHandled();
    }
    final run = ctx.runClassification;
    if (run == null) {
      conversation.host.showMessage('Project index unavailable.\n');
    } else {
      await run(conversation, options);
    }
    return const CmdHandled();
  }
}
