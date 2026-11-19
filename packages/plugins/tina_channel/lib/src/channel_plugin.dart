import 'dart:math';

import 'package:tina_engine_2/tina_engine_2.dart';

import '../channel_store_api.dart';
import 'channel_start.dart';
import 'channel_tools.dart';
import 'channel_watcher.dart';
import 'session_chat.dart';
import 'shortcode.dart';

/// Owns the channel store and contributes the channel tools — but the
/// chat is OPT-IN: until the user approved one (or a chat from an
/// earlier run of this session exists), the plugin is DORMANT — no
/// store, no room, and every channel tool answers with the
/// not-started refusal.
///
/// Starting goes through `channel_start` (main agents only): the main
/// agent proposes a chat, [approveStart] routes the proposal through
/// the session's approval machinery as a user decision, and only an
/// approval opens the store (`channels/<session-id>.db`), creates the
/// channel, joins the main agent and records the human's member row.
/// A decline creates nothing and the ask may not repeat within the
/// same user turn.
///
/// When a chat exists (started here, or found at open via [chatExists]
/// — resuming a session reattaches its chat with full history), the
/// plugin behaves as it always did: identity settled at the
/// composition seam (an explicit [agentName], or a generated shortcode
/// collision-checked against the chat's active members), `#lobby`
/// joined so the session sees its agents, passive delivery at each
/// turn boundary, and the store closed with the session. A subagent
/// child passes its PARENT's id ([chatSessionId]) and joins the
/// session's chat with role `subagent`; children cannot start rooms.
///
/// The pane learns about a started chat through the [SessionChatLifecycle]
/// face this plugin implements (the registry hands the plugin itself to
/// dependents), never by touching the store or the tools.
final class ChannelPlugin extends AgentPlugin
    implements SessionChatLifecycle {
  ChannelPlugin({
    required this.openStore,
    this.chatExists,
    this.chatSessionId,
    this.agentName,
    this.role = 'agent',
    this.humanName = 'user',
    this.approveStart,
    this.random,
    this.terminal,
  });

  /// Opens the chat store for a session id (creating it).
  final ChannelStoreOpener openStore;

  /// Whether a chat store already exists for a scope — the resume
  /// probe. Null (or false everywhere) means the session starts
  /// dormant. The default store seam supplies a file-existence check.
  final bool Function(String chatSessionId)? chatExists;

  /// The session whose chat this plugin talks in: the session's own id
  /// when null; a subagent child sets its parent's id.
  final String? chatSessionId;

  /// The agent identity messages self-attribute with: an explicit
  /// override, or null to generate a per-session shortcode.
  final String? agentName;

  /// The presence role written with membership rows (`main`, `agent`,
  /// task label). `main` is also what `channel_start` requires.
  final String role;

  /// The name the session's human posts under. Recorded as a member
  /// row when a chat is started, and never filtered by the watcher.
  final String humanName;

  /// The user-approval seam for `channel_start`. Null refuses starts
  /// (compositions without an approval path never create chats).
  final ChannelStartApprover? approveStart;

  /// The randomness source for shortcode generation (tests inject a
  /// scripted one; sessions pass nothing).
  final Random? random;

  /// Where the non-fatal "group chat unavailable" notice goes; null
  /// keeps headless compositions quiet.
  final Terminal? terminal;

  /// The shared lifecycle's backing signal (the [SessionChatLifecycle]
  /// face delegates here).
  final SessionChat _sessionChat = SessionChat();

  @override
  bool get isStarted => _sessionChat.isStarted;

  @override
  Stream<void> get changes => _sessionChat.changes;

  ChannelStoreApi? _store;
  ChannelTools? _tools;
  ChannelWatcher? _watcher;
  String? _effectiveName;
  String? _scope;
  String? _startedChannel;

  /// Why a chat that exists could not be opened (non-fatal): the
  /// session started without the chat, the tools refuse, and
  /// `channel_start` retries the open on approval.
  String? _openFailure;

  /// The user turn currently running (for the one-ask-per-turn rule).
  int _turn = 0;
  int? _declinedTurn;

  /// The settled identity once the chat has been started (the override
  /// verbatim, or the generated shortcode); null before.
  String? get name => _effectiveName;

  /// The chat's store once started — a UI may borrow it for reads and
  /// must never close it; null while dormant.
  ChannelStoreApi? get storeForUi => _store;

  /// The channel the approved `channel_start` created, when this
  /// process started the chat (null when an earlier run did).
  String? get startedChannel => _startedChannel;

  @override
  String get id => 'tina/channel';

  @override
  List<ToolSchema> get tools => _tools == null
      ? const []
      : [channelStartTool, ..._tools!.tools];

  @override
  SessionSeed? openSession(PluginSession session) {
    _scope = chatSessionId ?? session.id;
    if (chatExists?.call(_scope!) ?? false) {
      try {
        // Resume: this session ran before and started a chat —
        // reattach it (full history, presence, cursor pinning)
        // exactly as before.
        _activate();
      } on Object catch (error) {
        // Non-fatal: one component's storage failure must never abort
        // the session. The chat stays dormant (the tools refuse, the
        // pane never learns of a start), the notice says why, and
        // `channel_start` retries the open on approval.
        _openFailure = 'group chat unavailable: $error';
        terminal?.writeln(_openFailure!);
        _tools = ChannelTools(agentName: agentName ?? 'unsettled', role: role);
      }
    } else {
      // Dormant: no store, no room. The tools exist (stable toolset)
      // but every call answers with the not-started refusal until a
      // `channel_start` the user approves.
      _tools = ChannelTools(agentName: agentName ?? 'unsettled', role: role);
    }
    return null;
  }

  @override
  void mountOn(AgentLoop loop) {
    // All five executors are registered even while dormant, so a call
    // always reaches this plugin and gets a named refusal instead of
    // an unknown-tool error.
    for (final name in [
      'channel_start',
      ...ChannelTools.toolNames,
    ]) {
      loop.registerContextExecutor(
          name, (input, context) => execute(name, input, context: context));
    }
  }

  /// Executes a channel tool call. Public for tests; the loop executor
  /// registered by [mountOn] lands here.
  Future<ToolResult> execute(String name, Map<String, Object?> input,
      {ToolExecutionContext? context}) async {
    if (context?.isCancelled() == true) {
      return ToolResult.error('channel request cancelled');
    }
    if (name == 'channel_start') return _start(input, context);
    final tools = _tools;
    if (tools == null) throw FormatException('unknown tool $name');
    return tools.execute(name, input, context: context);
  }

  Future<ToolResult> _start(
      Map<String, Object?> input, ToolExecutionContext? context) async {
    // Main agents start rooms; subagents join them. The refusal names
    // the rule so a child does not retry blind.
    if (role != 'main') {
      return ToolResult.error('Only the main agent starts the session\'s '
          'group chat; subagents join the chat once it exists.');
    }
    if (isStarted) {
      return ToolResult('A group chat is already started for this session'
          '${_startedChannel == null ? '' : ' ($_startedChannel)'}; '
          'channel_say, channel_read and channel_status work.');
    }
    if (_declinedTurn == _turn) {
      return ToolResult.error('The user already declined to start a group '
          'chat in this turn; ask again only in a later turn.');
    }
    String channel = '#lobby';
    String? purpose;
    try {
      final parsed = parseChannelStartInput(input);
      channel = parsed.$1;
      purpose = parsed.$2;
    } on FormatException catch (e) {
      return ToolResult.error('$e');
    }
    final approver = approveStart;
    if (approver == null) {
      return ToolResult.error('Starting a group chat requires the user\'s '
          'approval, which this composition does not provide.');
    }
    final approved = await approver(
        channel: channel,
        purpose: purpose,
        members: 'the main agent, its subagents, and the human '
            '($humanName)');
    if (context?.isCancelled() == true) {
      return ToolResult.error('channel request cancelled');
    }
    if (!approved) {
      // One ask per user turn: the decline is final for this turn.
      _declinedTurn = _turn;
      return ToolResult.error('The user declined to start a group chat for '
          'this session; nothing was created.');
    }
    if (isStarted) {
      // Two asks raced in one batch; the first one created the chat.
      return ToolResult('A group chat is already started for this session '
          '($_startedChannel); nothing duplicated.');
    }
    try {
      _activate(startChannel: channel);
      _openFailure = null;
    } on Object catch (e) {
      _openFailure = 'group chat unavailable: $e';
      return ToolResult.error('could not open the group chat: $e');
    }
    return ToolResult('Group chat started: $channel created and joined as '
        '$name (the human $humanName is a member, and the channel pane '
        'is now visible). channel_say, channel_read and channel_status '
        'are live; subagents join only in swarm mode — launch_subagent '
        'with channel: true.');
  }

  /// Opens the store and joins. [startChannel] is the channel an
  /// approved `channel_start` created: the main agent joins it (and
  /// `#lobby`, so the session sees its agents) and the human's member
  /// row is recorded — silently, because the pane announces the human
  /// on its first view of a channel. Without [startChannel] (resume)
  /// this is exactly the historical session-open path.
  void _activate({String? startChannel}) {
    final store = openStore(_scope!);
    final String identity;
    try {
      identity = agentName ?? settleAgentName(store, random);
      if (startChannel != null) store.ensureChannel(startChannel);
      store.setMember('#lobby', identity,
          status: 'working', role: role, announce: true);
      if (startChannel != null && startChannel != '#lobby') {
        store.setMember(startChannel, identity,
            status: 'working', role: role, announce: true);
      }
      if (startChannel != null) {
        store
          ..setMember('#lobby', humanName,
              status: 'joined', role: 'human', announce: false)
          ..setMember(startChannel, humanName,
              status: 'joined', role: 'human', announce: false);
      }
    } on Object {
      store.close();
      rethrow;
    }
    _store = store;
    _effectiveName = identity;
    _startedChannel ??= startChannel;
    _tools =
        ChannelTools(store: store, agentName: identity, role: role);
    _watcher = ChannelWatcher.start(
        store: store, agent: identity, human: humanName);
    _sessionChat.markStarted();
  }

  @override
  void onPrompt(TurnContext context) {
    _turn++;
    // A subagent spawned before the chat was started notices it at its
    // next turn boundary (a cheap existence probe — the main agent
    // gets the direct start signal through _activate).
    if (!isStarted && _scope != null) {
      try {
        if (chatExists?.call(_scope!) ?? false) {
          _activate();
          _openFailure = null;
        }
      } on Object catch (error) {
        // Optional reattach: a failing probe keeps the session alive
        // and the tools refusing.
        _openFailure ??= 'group chat unavailable: $error';
      }
    }
    _tools?.onPrompt(context);
    // Turn-boundary delivery: everything routed to this agent since
    // its previous turn rides one prompt section, then the cursor is
    // marked. The section is rebuilt per turn, so a delivered batch is
    // visible for exactly the turn that consumed it.
    final section = _watcher?.deliverPending();
    if (section != null) context.promptSections.add(section);
  }

  @override
  void closeSession() {
    _watcher?.close();
    _watcher = null;
    _tools = null;
    _store?.close();
    _store = null;
    _effectiveName = null;
    _scope = null;
    _startedChannel = null;
    _declinedTurn = null;
    _sessionChat.dispose();
  }
}
