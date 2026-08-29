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
  final Future<CmdResult> Function(SessionCommandHandlers handlers,
      String trimmed) handler;

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
    names: const ['/exit', '/quit'],
    argsHint: '',
    summary: 'quit (inside tmux: Detach / Exit / Cancel)',
    helpOrder: 18,
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
    handler: (h, _) => _handled(h._handleClear),
  ),
  SessionCommandEntry(
    names: const ['/compact'],
    argsHint: '',
    summary: 'summarize history to free context',
    helpOrder: 4,
    handler: (h, _) => _handled(h._handleCompact),
  ),
  SessionCommandEntry(
    names: const ['/auto-compact'],
    argsHint: '',
    summary: 'show/set the auto-compact threshold (off|<n>)',
    helpOrder: 5,
    handler: (h, t) => _handled(() => h._handleAutoCompact(t)),
  ),
  SessionCommandEntry(
    names: const ['/permissions'],
    argsHint: '',
    summary: 'show permission rules; /permissions <mode> switches mode',
    helpContinuation: '(ask | read-all | allow-edits | auto)',
    helpOrder: 10,
    handler: (h, t) => _handled(() => h._handlePermissions(t)),
  ),
  SessionCommandEntry(
    names: const ['/sessions'],
    argsHint: '',
    summary: 'open the session picker (switch/resume); lists them headless',
    helpOrder: 11,
    handler: (h, _) => _handled(h._printSavedSessions),
  ),
  SessionCommandEntry(
    names: const ['/session'],
    argsHint: '',
    summary: 'list live sessions; new/switch/close',
    helpOrder: 12,
    handler: (h, t) => _handled(() => h._handleSessionCommand(t)),
  ),
  SessionCommandEntry(
    names: const ['/resume'],
    argsHint: '<id>',
    summary: 'load a saved session into the active session',
    helpOrder: 13,
    handler: (h, t) => _handled(() => h._handleResume(t)),
  ),
  SessionCommandEntry(
    names: const ['/save'],
    argsHint: '<path>',
    summary: 'export this session as a markdown transcript',
    helpOrder: 14,
    handler: (h, t) => _handled(() => h._handleSave(t)),
  ),
  SessionCommandEntry(
    names: const ['/model'],
    argsHint: '',
    summary: 'pick a provider/model for the active session',
    helpOrder: 6,
    handler: (h, t) => _handled(() => h._handleModel(t)),
  ),
  SessionCommandEntry(
    names: const ['/settings'],
    argsHint: '',
    summary: 'reconfigure providers/models/tiers (applies on restart)',
    helpOrder: 15,
    handler: (h, _) => _handled(h._handleSettings),
  ),
  SessionCommandEntry(
    names: const ['/prompts'],
    argsHint: '',
    summary: "edit each agent role's system prompt (applies on restart)",
    helpOrder: 17,
    handler: (h, _) => _handled(h._handlePrompts),
  ),
  SessionCommandEntry(
    names: const ['/spawn'],
    argsHint: '',
    summary: 'open the spawn overlay (interactive TUI)',
    helpOrder: 0,
    inHelp: false,
    handler: (h, _) => _handled(h._handleSpawn),
  ),
  SessionCommandEntry(
    names: const ['/branch'],
    argsHint: '',
    summary: 'fork the active conversation into a new panel (copies its '
        'history)',
    helpOrder: 2,
    handler: (h, _) => _handled(h._handleBranch),
  ),
  SessionCommandEntry(
    names: const ['/image'],
    argsHint: '<path>',
    summary: 'render an image in the focused panel',
    helpOrder: 7,
    handler: (h, t) => _handled(() => h._handleImage(t)),
  ),
  SessionCommandEntry(
    names: const ['/index'],
    argsHint: '',
    summary: 'refresh the per-directory summary index (staleness-aware, runs '
        'in the background)',
    helpOrder: 8,
    handler: (h, _) => h._handleIndex(),
  ),
  SessionCommandEntry(
    names: const ['/workflow'],
    argsHint: '',
    summary: 'list/show/new/edit/run DOT pipelines (/workflow '
        'show|new|edit|run <name>)',
    helpOrder: 9,
    handler: (h, t) => _handled(() => handleWorkflowCommand(h.ctx, t)),
  ),
  SessionCommandEntry(
    names: const ['/output'],
    argsHint: '[n]',
    summary: 'full output of the most recent capped tool call, or the n-th '
        '(newest first)',
    helpOrder: 0,
    inHelp: false,
    handler: (h, t) => _handled(() => h._handleOutput(t)),
  ),
  SessionCommandEntry(
    names: const ['/spend'],
    argsHint: '',
    summary: "show this session's token usage and spend caps",
    helpOrder: 0,
    inHelp: false,
    handler: (h, _) => _handled(h._handleSpend),
  ),
  SessionCommandEntry(
    names: const ['/update'],
    argsHint: '',
    summary: 'check GitHub for a newer release and install it',
    helpOrder: 16,
    handler: (h, _) => _handled(h._handleUpdate),
  ),
  SessionCommandEntry(
    names: const ['/detach'],
    argsHint: '',
    summary: 'return to the shell, keep the agent running (tmux; also Alt+D)',
    helpOrder: 19,
    handler: (h, _) => _handled(h._handleDetach),
  ),
];

/// The ordered command table dispatch, completion, and `/help` render from.
/// Holds [SessionCommandEntry]s in dispatch/completion order; `/help` reorders
/// by each entry's [SessionCommandEntry.helpOrder].
class SessionCommandRegistry {
  const SessionCommandRegistry(this.commands);

  /// Every entry, in dispatch/completion order (primary names first, then
  /// aliases).
  final List<SessionCommandEntry> commands;

  /// Every recognized name (primary names and aliases, flattened in registry
  /// order) — the `/` completion palette's offering.
  List<String> get allNames => [
        for (final entry in commands) ...entry.names,
      ];

  /// Looks a typed word up by name. Aliases resolve to their shared entry.
  /// Returns null for anything unrecognized (the caller decides between the
  /// unknown-command error and [CmdNotCommand] by whether the word starts
  /// with `/`).
  SessionCommandEntry? lookup(String word) {
    for (final entry in commands) {
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
    final visible = commands.where((e) => e.inHelp).toList()
      ..sort((a, b2) => a.helpOrder.compareTo(b2.helpOrder));
    for (final entry in visible) {
      final label = '${entry.primary} ${entry.argsHint}'.trim();
      b.write('  ${label.padRight(15)}${entry.summary}\n');
      final continuation = entry.helpContinuation;
      if (continuation != null) {
        b.write('  ${''.padRight(15)}$continuation\n');
      }
    }
    b.write("ESC cancels the active session's in-flight response.\n");
    return b.toString();
  }
}
