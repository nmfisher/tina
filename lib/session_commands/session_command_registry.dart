part of 'session_command_handlers.dart';

/// One built-in slash command: its names, the metadata completion and `/help`
/// render from, and the handler that runs on dispatch.
///
/// Plain data plus a closure: [names] is primary-first (aliases share the
/// entry — `/exit` + `/quit`), [argsHint] is the argument part of the typed
/// usage (rendered after the name, e.g. `/image <path>`), [summary] is the
/// one-line description. [handler] receives the [SessionCommandHandlers]
/// instance dispatching the command and the full trimmed line, mirroring the
/// per-case bodies of the pre-registry switch one-for-one.
class SessionCommandEntry {
  const SessionCommandEntry({
    required this.names,
    required this.argsHint,
    required this.summary,
    required this.handler,
    required this.helpOrder,
    this.helpContinuation,
    this.inHelp = true,
    this.feature,
  });

  /// Typed names, primary first, then aliases. All names dispatch to [handler]
  /// and are offered by the `/` completion palette; only [names.first] renders
  /// in `/help`.
  final List<String> names;

  /// Argument hint rendered after the primary name (empty for no args).
  final String argsHint;

  /// One-line description (the `/help` text for this command).
  final String summary;

  /// Runs the command. Returns the dispatch result — `CmdExit` for `/exit`,
  /// `CmdHandled` for everything else (see [_handled]).
  final Future<CmdResult> Function(
    SessionCommandHandlers handlers,
    String trimmed,
  )
  handler;

  /// Position in the `/help` listing. The help order is the historical
  /// documentation order, which differs from the registry (completion) order.
  final int helpOrder;

  /// Optional second help line, rendered under the description column (used by
  /// `/permissions`, whose description wraps).
  final String? helpContinuation;

  /// Whether the primary name renders in `/help`. Every built-in rendered
  /// today except `/spawn`, `/output` and `/spend` (surfaced elsewhere in the
  /// UI), so those three carry `false`.
  final bool inHelp;

  /// Optional feature this command belongs to (`null` = always available).
  /// A command whose feature is disabled by [SessionCommandRegistry] does not
  /// exist for dispatch, `/help`, or the `/` completion palette. Used by
  /// `/workflow`, whose surface ships off (see [RuntimeConfig.enableWorkflow]).
  final String? feature;

  /// The name completion and help render: the primary name.
  String get primary => names.first;
}

/// Wraps a void handler so every non-exit entry returns [CmdHandled], exactly
/// as the pre-registry switch's fall-through did.
Future<CmdResult> _handled(FutureOr<void> Function() action) async {
  await action();
  return const CmdHandled();
}

/// The ordered registry of built-in commands — the source of truth for
/// dispatch, the `/` completion palette, and (through the entries' help
/// metadata) `/help`. Order is the historical `allCommands` order (primary
/// name first, then aliases); the `/help` order is each entry's [SessionCommandEntry.helpOrder].
final List<SessionCommandEntry> _kSessionCommandEntries = [
  SessionCommandEntry(
    names: const ['/explore'],
    argsHint: '<implementation question>',
    summary: 'locate code using Typesafe scouts (no direct filesystem tools)',
    // Timers pushed the visible /detach 19 -> 20; this hidden entry keeps its
    // sort slot after /classifier-review (24) so no two entries share an order.
    helpOrder: 25,
    handler: (h, line) async {
      final question = line.substring('/explore'.length).trim();
      if (question.isEmpty || question.length > 2000) {
        h.ctx.active.host.showMessage(
          'Usage: /explore <implementation question, up to 2000 characters>\n',
          style: HostMessageStyle.error,
        );
        return const CmdHandled();
      }
      return CmdRun(explorationTurnPrompt(question));
    },
  ),
  SessionCommandEntry(
    names: const ['/exit', '/quit'],
    argsHint: '',
    summary: 'quit (inside tmux: Detach / Exit / Cancel)',
    helpOrder: 19,
    handler: (_, _) async => const CmdExit(),
  ),
  SessionCommandEntry(
    names: const ['/help'],
    argsHint: '',
    summary: 'show this list',
    helpOrder: 1,
    handler: (h, _) => _handled(h._printHelp),
  ),
  SessionCommandEntry(
    names: const ['/clear'],
    argsHint: '',
    summary: "reset this session's history",
    helpOrder: 3,
    handler: (h, _) => _handled(h.history._handleClear),
  ),
  SessionCommandEntry(
    names: const ['/compact'],
    argsHint: '',
    summary: 'summarize history to free context',
    helpOrder: 4,
    handler: (h, _) => _handled(h.history._handleCompact),
  ),
  SessionCommandEntry(
    names: const ['/auto-compact'],
    argsHint: '',
    summary: 'show/set the auto-compact threshold (off|<n>)',
    helpOrder: 5,
    handler: (h, t) => _handled(() => h.history._handleAutoCompact(t)),
  ),
  SessionCommandEntry(
    names: const ['/permissions'],
    argsHint: '',
    summary: 'show permission rules; /permissions <mode> switches mode',
    helpContinuation: '(ask | read-all | allow-edits | auto)',
    helpOrder: 10,
    handler: (h, t) => _handled(() => h.permissions._handlePermissions(t)),
  ),
  SessionCommandEntry(
    names: const ['/sessions'],
    argsHint: '',
    summary: 'open the session picker (switch/resume); lists them headless',
    helpOrder: 11,
    handler: (h, _) => _handled(h.sessions._printSavedSessions),
  ),
  SessionCommandEntry(
    names: const ['/session'],
    argsHint: '',
    summary: 'list live sessions; new/switch/close',
    helpOrder: 12,
    handler: (h, t) => _handled(() => h.sessions._handleSessionCommand(t)),
  ),
  SessionCommandEntry(
    names: const ['/resume'],
    argsHint: '<id>',
    summary: 'load a saved session into the active session',
    helpOrder: 13,
    handler: (h, t) => _handled(() => h.sessions._handleResume(t)),
  ),
  SessionCommandEntry(
    names: const ['/timers'],
    argsHint: '[show|cancel <name>]',
    summary: "list this session's scheduled checks; show or cancel one",
    // Sits between /resume and /save (§9: "helpOrder next to the session
    // commands" — the /resume / /timers / /save block).
    helpOrder: 14,
    handler: (h, t) => _handled(() => h.timers._handleTimers(t)),
  ),
  SessionCommandEntry(
    names: const ['/save'],
    argsHint: '<path>',
    summary: 'export this session as a markdown transcript',
    // Timers pushed /save from 14 to 15 (the §9 /resume / /timers / /save block).
    helpOrder: 15,
    handler: (h, t) => _handled(() => h.sessions._handleSave(t)),
  ),
  SessionCommandEntry(
    names: const ['/model'],
    argsHint: '',
    summary: 'pick a provider/model for the active session',
    helpOrder: 6,
    handler: (h, t) => _handled(() => h.frontend._handleModel(t)),
  ),
  SessionCommandEntry(
    names: const ['/settings'],
    argsHint: '',
    summary:
        'configure providers, models and live quotas (theme needs restart)',
    helpOrder: 16,
    handler: (h, _) => _handled(h.frontend._handleSettings),
  ),
  SessionCommandEntry(
    names: const ['/prompts'],
    argsHint: '',
    summary: "edit each agent role's system prompt (applies on restart)",
    helpOrder: 18,
    handler: (h, _) => _handled(h.frontend._handlePrompts),
  ),
  SessionCommandEntry(
    names: const ['/spawn'],
    argsHint: '',
    summary: 'open the spawn overlay (interactive TUI)',
    helpOrder: 0,
    inHelp: false,
    handler: (h, _) => _handled(h.frontend._handleSpawn),
  ),
  SessionCommandEntry(
    names: const ['/branch'],
    argsHint: '',
    summary:
        'fork the active conversation into a new panel (copies its '
        'history)',
    helpOrder: 2,
    handler: (h, _) => _handled(h.frontend._handleBranch),
  ),
  SessionCommandEntry(
    names: const ['/image'],
    argsHint: '<path>',
    summary: 'render an image in the focused panel',
    helpOrder: 7,
    handler: (h, t) => _handled(() => h.frontend._handleImage(t)),
  ),
  SessionCommandEntry(
    names: const ['/index'],
    argsHint: '[jev|extensions] [status|refresh|view]',
    summary: 'classify languages, frameworks and tooling',
    helpOrder: 8,
    handler: (h, t) => h.index._handleIndex(t),
  ),
  SessionCommandEntry(
    names: const ['/workflow'],
    argsHint: '',
    summary:
        'list/show/new/edit/run DOT pipelines (/workflow '
        'show|new|edit|run <name>)',
    helpOrder: 9,
    // Ships off with the rest of the workflow surface (see
    // RuntimeConfig.enableWorkflow); restored by --enable-workflow or
    // [features] workflow = true.
    feature: kWorkflowFeature,
    handler: (h, t) => _handled(() => handleWorkflowCommand(h.workflow, t)),
  ),
  SessionCommandEntry(
    names: const ['/blocks'],
    argsHint: '',
    summary: 'list the transcript blocks that can fold, numbered',
    helpOrder: 21,
    handler: (h, _) => _handled(h.frontend._handleBlocks),
  ),
  SessionCommandEntry(
    names: const ['/show'],
    argsHint: '<n|all>',
    summary: 'reveal a folded block (a tool call\'s output, a thought)',
    helpOrder: 22,
    handler: (h, t) => _handled(() => h.frontend._handleFold(t, show: true)),
  ),
  SessionCommandEntry(
    names: const ['/hide'],
    argsHint: '<n|all>',
    summary: 'collapse a block back to its one-line form',
    helpOrder: 23,
    handler: (h, t) => _handled(() => h.frontend._handleFold(t, show: false)),
  ),
  SessionCommandEntry(
    names: const ['/spend'],
    argsHint: '',
    summary: "show this session's token usage and spend caps",
    helpOrder: 0,
    inHelp: false,
    handler: (h, _) => _handled(h.usage._handleSpend),
  ),
  SessionCommandEntry(
    names: const ['/update'],
    argsHint: '',
    summary: 'check GitHub for a newer release and install it',
    helpOrder: 17,
    handler: (h, _) => _handled(h.update._handleUpdate),
  ),
  SessionCommandEntry(
    names: const ['/detach'],
    argsHint: '',
    summary: 'return to the shell, keep the agent running (tmux; also Alt+D)',
    helpOrder: 20,
    handler: (h, _) => _handled(h.frontend._handleDetach),
  ),
  SessionCommandEntry(
    names: const ['/classifier-review'],
    argsHint: '[focus]',
    summary: 'review this session for Typesafe question ideas (fresh context)',
    helpOrder: 24,
    handler: (h, t) => _handled(() => h.history._handleClassifierReview(t)),
  ),
];

/// The ordered command table dispatch, completion, and `/help` render from.
/// Holds [SessionCommandEntry]s in dispatch/completion order; `/help` reorders
/// by each entry's [SessionCommandEntry.helpOrder].
class SessionCommandRegistry {
  const SessionCommandRegistry(this.commands, {this.hiddenFeatures = const {}});

  /// Every entry, in dispatch/completion order (primary names first, then
  /// aliases).
  final List<SessionCommandEntry> commands;

  /// Features whose commands do not exist for this registry — dispatch, help,
  /// and completion all read [available], so a disabled feature cannot be
  /// half-hidden (advertised by completion but rejected by dispatch, or vice
  /// versa).
  final Set<String> hiddenFeatures;

  /// The entries whose feature is enabled, in registry order.
  Iterable<SessionCommandEntry> get available => commands.where(
    (e) => e.feature == null || !hiddenFeatures.contains(e.feature),
  );

  /// Every recognized name (primary names and aliases, flattened in registry
  /// order) — the `/` completion palette's offering.
  List<String> get allNames => [for (final entry in available) ...entry.names];

  /// Looks a typed word up by name. Aliases resolve to their shared entry.
  /// Returns null for anything unrecognized (the caller decides between the
  /// unknown-command error and [CmdNotCommand] by whether the word starts
  /// with `/`), and for a command whose feature is disabled.
  SessionCommandEntry? lookup(String word) {
    for (final entry in available) {
      if (entry.names.contains(word)) return entry;
    }
    return null;
  }

  /// Renders the `/help` text from the registry, byte-identical to the
  /// pre-registry literal (golden-tested): two-space indent, name+argsHint
  /// padded to column 15, then the description, in [SessionCommandEntry.helpOrder]
  /// order; aliases and [SessionCommandEntry.inHelp]-false entries don't
  /// render; the ESC footer is a literal.
  String renderHelp() {
    final b = StringBuffer('Commands:\n');
    final visible = available.where((e) => e.inHelp).toList()
      ..sort((a, b2) => a.helpOrder.compareTo(b2.helpOrder));
    for (final entry in visible) {
      final label = '${entry.primary} ${entry.argsHint}'.trim();
      b.write(
        '  ${label.padRight(15)}${label.length >= 15 ? ' ' : ''}${entry.summary}\n',
      );
      final continuation = entry.helpContinuation;
      if (continuation != null) {
        b.write('  ${''.padRight(15)}$continuation\n');
      }
    }
    b.write("ESC cancels the active session's in-flight response.\n");
    return b.toString();
  }
}
