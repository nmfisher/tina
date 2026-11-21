import 'dart:io';
import 'package:classification/command_regex.dart';
import 'package:classification/plugin.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_grok_guard/tina_grok_guard.dart';
import 'package:tina_activity/tina_activity.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'package:tina_rewind/tina_rewind.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';
import 'permission_instructions.dart';
import 'session_context.dart';

export 'session_context.dart';
import 'package:tina_shell/tina_shell.dart';
import 'package:tina_system_instruction/tina_system_instruction.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_channel/tina_channel.dart';
// The CONDITIONAL store seam, not `tina_channel_sqlite.dart`: this
// catalog's graph also compiles to Wasm (the TUI component reaches it
// through tui_presentation), where dart:ffi cannot go — the release
// wasm build broke on exactly that import. Natively this resolves to
// the same sqlite implementation.
import 'package:tina_channel/default_store.dart';
// Same conditional-seam discipline as the channel store: the catalog's
// graph compiles to Wasm; the memory opener resolves natively to the
// same sqlite implementation without dart:ffi in this graph.
import 'package:tina_memory/default_store.dart';
import 'package:tina_memory/tina_memory.dart' show MemoryPlugin;
import 'package:tina_goals/tina_goals.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_subagents/tina_subagents.dart';
import 'package:tina_file_resources/tina_file_resources.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_step_limit/tina_step_limit.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_tasks/tina_tasks.dart';
import 'package:tina_web_search/tina_web_search.dart';

/// Result count for the web_search tool. A setting, not a constant: heavy
/// researchers want more hits, token-pinched setups fewer.
final webSearchSetting = SettingDefinition<int>(
  id: 'tina/web-search/result_count',
  label: 'Web search results per call',
  description: 'Maximum results the web_search tool returns per call, 1–20.',
  defaultValue: 5,
  kind: SettingKind.integer,
  minimum: 1,
  maximum: 20,
  applyAt: ApplyAt.nextRequest,
);

final toolCallFormatSetting = SettingDefinition<bool>(
  id: 'tina/classification/tool_call_format',
  label: 'Check tool calls before running',
  description:
      'Use the configured Typesafe model to check command formatting and file paths. '
      'Ask the agent to rewrite concrete command or path mistakes before approval '
      'and execution. Requires tina/classification and a Typesafe API key.',
  defaultValue: true,
  kind: SettingKind.toggle,
  applyAt: ApplyAt.nextRequest,
);

final toolCallFormatTimeoutSetting = SettingDefinition<int>(
  id: 'tina/classification/tool_call_format_timeout_seconds',
  label: 'Tool call check timeout (seconds)',
  description:
      'Maximum time for a Typesafe tool call check. If unavailable '
      'or timed out, continue with normal permission checks.',
  defaultValue: 60,
  kind: SettingKind.integer,
  minimum: 1,
  maximum: 300,
  applyAt: ApplyAt.nextRequest,
);

const _workingContext = PluginCapability<ContextPlugin>('tina/working-context');

/// The session's chat lifecycle, provided by tina/channel (the channel
/// plugin itself is the value): the pane plugin receives it so the
/// pane can appear when the user approves a chat (opt-in start) —
/// mid-session, without a restart.
const _sessionChat =
    PluginCapability<SessionChatLifecycle>('tina/session-chat');

/// The model for permission-side judgments, shared by BOTH consumers:
/// the permission classifier and the command-pattern suggester. The
/// active profile's approver leg (or the Approver model setting) first,
/// then this conversation's current model. (The deprecated
/// tina/mode/classifier_model override was removed with v0.10.9;
/// configs still carrying the key load cleanly and ignore it.)
String _classifierModel(SessionPluginContext c) {
  final leg = c.approverModel?.call()?.trim();
  if (leg != null && leg.isNotEmpty) return leg;
  return c.currentModel();
}

/// Required host plugins also carry metadata, without becoming optional features.
List<PluginDefinition<SessionPluginContext>> basePluginDefinitions() => [
  PluginDefinition(
    'tina/system-instruction',
    (_) => const SystemInstructionPlugin(),
    description:
        'Supplies the agent identity and base instructions for conversations.',
  ),
  PluginDefinition(
    'tina/providers',
    (c) => c.providerPolicy!,
    cli: providersCli,
    settings: [...providerLimitSettings, ...profileSettings],
    provides: [modelAccess],
    // Structural: a session engine cannot serve a session without its
    // provider, even when the config names only unknown plugins (those
    // are skipped and recorded instead) - same as the wasm engine's
    // catalog.
    alwaysSelected: true,
    description:
        'Connects configured models and providers and enforces request and token limits.',
  ),
  PluginDefinition.dependingOn<SessionPluginContext, ModePolicySource>(
    'tina/mode',
    settings: classifierSettings,
    operations: modeOperations,
    dependency: modePolicySource,
    create: (c, source) => ModeControlsPlugin(source.modePolicy),
    live: true,
    description:
        'Adds /mode and Shift-Tab controls for the tools permission policy.',
  ),
];

Map<String, String> pluginDescriptions(
  PluginRegistry<SessionPluginContext> registry,
) => {
  for (final id in registry.ids) id: registry.definition(id).description,
  for (final definition in basePluginDefinitions())
    definition.id: definition.description,
};

/// This catalog alone grants first-party names. Extension registration on
/// the returned registry rejects the reserved namespace.
PluginRegistry<SessionPluginContext> firstPartyPlugins() => PluginRegistry(
  requiredCapabilities: [modelAccess],
  definitions: [
    ...basePluginDefinitions(),
    PluginDefinition<SessionPluginContext>(
      'tina/shell',
      (c) => ShellPlugin(
        terminal: c.terminal,
        workingDirectory: c.workingDirectory,
      ),
      description:
          'Runs !command or /shell command with your shell permissions, without sending it to a model.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/session-controls',
      (c) => SessionControlsPlugin(
        terminal: c.terminal,
        currentModel: c.currentModel,
        switchModel: c.switchModel,
        modelCatalog: c.modelCatalog,
        currentReasoning: c.currentReasoning,
        setReasoning: c.setReasoning,
        reasoningChoices: c.reasoningChoices,
        readProfiles: c.profiles,
        switchProfile: c.switchProfile,
        // /memory: the CLI's store-opening path (the conditional
        // default-store seam resolves to the same sqlite opener), one
        // pair per invocation, closed after. The wasm engine wires
        // this plugin without the seam, so /memory stays native-only.
        openMemoryStores: () => openDefaultMemoryStores(
            c.workingDirectory,
            environment: Platform.environment),
        readCacheStats: c.memoryCacheStats,
      ),
      settings: [defaultModelSetting, reasoningSetting],
      operations: sessionControlsOperations,
      description:
          'Switches the active conversation model and reasoning effort, and clears its context and display.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/rewind',
      (c) => RewindPlugin(terminal: c.terminal),
      operations: rewindOperations,
      description:
          'Rewinds the conversation to an earlier point with /rewind and the rewind picker, leaving the log append-only and the filesystem untouched.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/step-limit',
      (c) => StepLimitPlugin.configured(
        configPath: c.configPath,
        settings: c.settings,
      ),
      settings: [stepLimitSetting],
      description:
          'Optionally limits foreground model rounds per turn. Multiple tool calls in one response count as one round. Zero means unlimited.',
      live: true,
    ),
    grokGuardDefinition<SessionPluginContext>(),
    PluginDefinition.dependingOn<SessionPluginContext, ModePolicySource>(
      'tina/mcp',
      dependency: modePolicySource,
      create: (c, source) => McpPlugin.configured(
        store: McpConfigStore(c.configPath),
        workingDirectory: c.workingDirectory,
        terminal: c.terminal,
        approve: source.modePolicy.request,
      ),
      live: true,
      description:
          'Connects configured MCP servers, discovers their tools and resources, and routes calls through the current approval mode. Local server commands run with your account privileges.',
    ),
    PluginDefinition.dependingOn<SessionPluginContext, UpdateStatusSource>(
      'tina/update-tui',
      dependency: updateStatusSource,
      live: true,
      create: (_, status) =>
          PresentationPlugin(id: 'tina/update-tui', source: status),
      description:
          'Shows the running version and update availability in the status bar.',
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/status-strip-tui',
      (_) => PresentationPlugin(id: 'tina/status-strip-tui', source: null),
      description:
          'Arranges the status bar: how plugin lines and the mode label share the strip under width pressure.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/token-rate-tui',
      (_) => PresentationPlugin(id: 'tina/token-rate-tui', source: null),
      description:
          'Shows a live tokens-per-second gauge for the active model turn in the status bar.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/cwd-tui',
      (c) => PresentationPlugin(
        id: 'tina/cwd-tui',
        source: Directory(c.workingDirectory).absolute.path,
      ),
      description:
          'Shows the active session working directory in the status bar.',
      live: true,
    ),
    updateDefinition<SessionPluginContext>(
      version: (c) => c.version,
      terminal: (c) => c.terminal,
      restart: (c) => c.restart,
    ),
    approvalsDefinition<SessionPluginContext>(),
    PluginDefinition.dependingOn<SessionPluginContext, ModelAccess>(
      'tina/approvals-tui',
      dependency: modelAccess,
      provides: [approvalChannel],
      create: (c, models) {
        // Both editors draft through the same model lease; only the
        // instruction differs (full command vs starting-with rule).
        Future<CommandPatternSuggestion> suggest(
          CommandRegexSuggestionMode mode,
          ApprovalRequest request,
          Future<void> cancelled,
        ) async {
          final suggestion =
              await CommandRegexSuggester(
                () => models.mainProvider(_classifierModel(c)),
                mode: mode,
              ).suggest(
                request.details['command_pattern_target'] as String,
                whenCancelled: cancelled,
              );
          return (
            pattern: suggestion.pattern,
            explanation: suggestion.explanation,
            failure: suggestion.failure,
          );
        }

        return AttachmentApprovalChannel(
          suggestCommandPattern: (request, cancelled) =>
              suggest(CommandRegexSuggestionMode.exact, request, cancelled),
          suggestCommandPrefix: (request, cancelled) =>
              suggest(CommandRegexSuggestionMode.prefix, request, cancelled),
        );
      },
      description:
          'Shows approval choices and edits model-suggested command approval regexes.',
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/approvals-stream',
      (_) => StreamApprovalChannel(),
      provides: [approvalChannel],
      description:
          'Delivers approval requests through a stream for an external interaction channel.',
    ),
    PluginDefinition.dependingOn2<
      SessionPluginContext,
      ApprovalRequester,
      ModelAccess
    >(
      'tina/tools',
      cli: toolsCli,
      settings: executionSettings,
      first: approvalRequester,
      second: modelAccess,
      provides: [toolProvider, modePolicySource],
      create: (c, approvals, models) {
        // Capability-typed, never a payload cast (commit 28): both legs'
        // tools plugins declare ModePolicySource. When a composition
        // supplies none, the policy wiring degrades to absent — the
        // plugin itself still mounts.
        final source = c.capability<ModePolicySource>();
        if (source != null) {
          final policy = source.modePolicy;
          policy.approvals = approvals;
          policy.terminal = c.terminal;
          policy.classifier = PermissionClassifier(
            () => models.mainProvider(_classifierModel(c)),
            readTimeout: () => Duration(
              seconds:
                  c.settings?.read(classifierTimeoutSetting).value ??
                  classifierTimeoutSetting.defaultValue,
            ),
            // Private workspace preferences take precedence over the fallback.
            readInstruction: () =>
                readProjectPermissionInstructions(c.settings) ??
                c.settings?.read(classifierInstructionSetting).value ??
                '',
          );
        }
        return c.tools;
      },
      description:
          'Provides sandboxed file, search and shell tools with permission policy and approval routing.',
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ModelAccess>(
      'tina/classification',
      dependency: modelAccess,
      settings: [toolCallFormatSetting, toolCallFormatTimeoutSetting],
      create: (c, models) => ClassificationPlugin.configured(
        terminal: c.terminal,
        configPath: c.configPath,
        readWorkspace: () => c.workingDirectory,
        createProvider: () => models.mainProvider(c.currentModel()),
        toolCallFormatEnabled: () =>
            c.settings?.read(toolCallFormatSetting).value ?? true,
        toolCallFormatTimeout: () => Duration(
          seconds: c.settings?.read(toolCallFormatTimeoutSetting).value ?? 60,
        ),
      ),
      description:
          'Classifies user input and Git operations, learns reusable categories, '
          'and checks command formatting and file paths with Typesafe before execution. '
          'Requests rewrites for poorly formatted commands without granting permissions.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/panels-tui',
      (c) => PresentationPlugin(
        id: 'tina/panels-tui',
        source: null,
        commands: [
          Command(
            name: 'close',
            description: 'close the focused panel (Ctrl+X)',
            handler: (_) =>
                c.terminal.writeln('Panels require the interactive console.'),
          ),
        ],
      ),
      description:
          'Renders conversations in terminal panels with focus, minimize and '
          'close controls. Opening additional conversations from inside a '
          'running TUI was removed; start one by launching tina (or '
          '--resume/--continue).',
      live: false,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/chat-tui',
      (c) => ChatPlugin(
        model: c.model,
        tokenCap: c.limits.sessionTokens,
        currentTokenCap: () => c.currentLimits.sessionTokens,
        showSessionId: c.openStore != null,
        terminalAlertsEnabled: () =>
            c.settings?.read(terminalAlertsSetting).value ?? true,
        sessionTokens: c.providerPolicy == null
            ? null
            : () => c.providerPolicy!.sessionTokens,
        sessionEstimatedTokens: c.providerPolicy == null
            ? null
            : () => c.providerPolicy!.sessionEstimatedTokens,
      ),
      settings: [themeSetting, terminalAlertsSetting],
      description:
          'Displays conversation history, model responses, tool calls, timestamps and token spend.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/activity-tui',
      (c) => ActivityPlugin(terminal: c.terminal, printTranscript: false),
      description:
          'Shows tool progress, results, file diffs and subagent activity in the activity browser.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/bg-tui',
      (_) => PresentationPlugin(id: 'tina/bg-tui', source: null),
      description:
          'Shows running background processes in the status bar with a browsable list and live output (F5).',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/persistence',
      (c) => PersistencePlugin(
        openStore: c.openStore! as SessionStoreOpener,
        settings: c.settings,
        history: c.sessionStorePath == null
            ? null
            // The history tools ride the mode policy; a composition
            // without one (no ModePolicySource payload) mounts
            // persistence without the session-history surface.
            : c.capability<ModePolicySource>() == null
                ? null
                : SessionHistoryTools(
                    workspace: c.workingDirectory,
                    store: c.sessionStorePath!,
                    policy: c.capability<ModePolicySource>()!.modePolicy,
                    catalog: HistoryCatalog(
                      '${File(c.configPath).parent.path}/session-stores',
                    ),
                  ),
      ),
      description:
          'Saves conversations in SQLite, resumes sessions, and provides workspace-first history search with recent sessions first.',
      live: false,
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ApprovalRequester>(
      'tina/channel',
      dependency: approvalRequester,
      provides: [_sessionChat],
      create: (c, approvals) => ChannelPlugin(
        // A chat belongs to one session: the opener receives the
        // session id (the host's own identity) and opens that
        // session's chat file. Resuming reopens the same chat.
        openStore: (scope) =>
            openDefaultChannelStore(c.workingDirectory, scope),
        // Opt-in/resume probe: a chat that already exists (an earlier
        // run of this session started one) reattaches at open; a
        // fresh session starts dormant.
        chatExists: (scope) =>
            defaultChannelStoreExists(c.workingDirectory, scope),
        // Identity is decided at the assembly root: an explicit
        // TINA_AGENT_NAME wins verbatim; otherwise the plugin draws a
        // per-session shortcode, collision-checked against the chat.
        agentName:
            agentNameFromEnvironment(Platform.environment),
        role: 'main',
        // The watcher never filters the human: it must know the name
        // the person at this terminal posts under.
        humanName: defaultHumanName(Platform.environment),
        // A chat store that cannot open must not abort the session:
        // the notice names it, the session starts chatless.
        terminal: c.terminal,
        // channel_start is a proposal the USER decides: a Yes/No
        // confirmation showing what would be created. Declined (or
        // cancelled, or timed out) creates nothing.
        approveStart:
            ({required String channel, String? purpose, required String members}) async {
          final decision = await approvals.request(
            operation: 'start group channel',
            target: channel,
            reason: 'Create this session\'s group chat $channel?'
                '${purpose == null ? '' : ' Purpose: $purpose.'}'
                ' Members: $members. Messages persist with the session '
                'in this workspace and the channel pane opens for you.',
            kind: ApprovalKind.confirmation,
            details: {
              'channel': channel,
              if (purpose != null) 'purpose': purpose,
              'members': members,
            },
          );
          return switch (decision) {
            ApprovalDecision.allow ||
            ApprovalDecision.allowAlways ||
            ApprovalDecision.allowWorkspace ||
            ApprovalDecision.allowGlobal => true,
            _ => false,
          };
        },
      ),
      description:
          'The session\'s opt-in group chat: the main agent proposes one '
          '(channel_start) and the user approves; then the main agent, its '
          'subagents and the human share channels with scrollback and '
          'presence, persisted with the session in the workspace.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/memory',
      (c) {
        final plugin = MemoryPlugin(
          // Rolling memory is keyed by repo ORIGIN (cross-checkout
          // learning, issue 94): the opener resolves the git remote
          // and opens ~/.tina/memory/<origin>.db plus the global
          // tier — never a workspace path, so every checkout shares
          // one memory.
          openStores: () =>
              openDefaultMemoryStores(c.workingDirectory),
        );
        // The answer cache rides the session's process runner: serve
        // before a certified read-only search runs, capture after it
        // succeeds. The closures dereference lazily — the cache
        // exists once the session opens (before that, the seams are
        // inert by design). A composition without a process runner
        // (the wasm-shaped leg) mounts memory without the cache
        // hooks — a noticed, first-class absence, never a cast.
        final runner = c.capability<ToolsPluginSurface>()?.processRunner;
        if (runner != null) {
          runner.readOnlySearchResolver =
              (String program, List<String> arguments) {
            final cache = plugin.answerCache;
            if (cache == null) return null;
            final served = cache.serve(_query(program, arguments));
            return served == null ? null : cache.injectionBlock(served);
          };
          runner.onReadOnlySearchCompleted =
              (String program, List<String> arguments,
                  List<String> files) {
                plugin.answerCache?.capture(
                    _query(program, arguments), files);
              };
        } else {
          c.terminal.writeln(
              'memory: no process runner in this composition — the '
              'answer cache stays disabled');
        }
        return plugin;
      },
      description:
          'Rolling memory: durable facts about this repository shared '
          'across its checkouts (origin-keyed), with remember/recall/'
          'forget tools, a session-start hot tier and an answer cache '
          'that serves repeated searches from verified pointers.',
      live: true,
    ),
    PluginDefinition.dependingOn<SessionPluginContext, SessionChatLifecycle>(
      'tina/channel-tui',
      dependency: _sessionChat,
      create: (c, chat) => ChannelPanePlugin(
        openStore: (scope) =>
            openDefaultChannelStore(c.workingDirectory, scope),
        // The shared chat lifecycle: the pane stays absent until a
        // chat is started, then goes live mid-session.
        chat: chat,
        // The human identity is decided at the assembly root like the
        // agent's: an explicit TINA_HUMAN_NAME wins verbatim, else the
        // OS username sanitized (see human_identity.dart).
        humanName: defaultHumanName(Platform.environment),
      ),
      description:
          'Shows the session\'s group chat in the console — once the user '
          'approved one (channel_start): channel list with unread badges, '
          'recent messages, and an input line — typing posts to the channel '
          'as the human. Appears live in the side column when the chat is '
          'created.',
      live: true,
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ApprovalRequester>(
      'tina/plans',
      dependency: approvalRequester,
      create: (c, approvals) => PlansPlugin(
        terminal: c.terminal,
        // Plan consent is always human, never a tool-safety judgment.
        approver: (request, reason) async {
          final decision = await approvals.request(
            operation: 'approve plan',
            target: request.path,
            reason: reason,
            kind: ApprovalKind.confirmation,
          );
          return decision == ApprovalDecision.allow
              ? Approval.yes
              : Approval.no;
        },
      ),
      description:
          'Lets the agent maintain a task plan and track progress through its steps.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/goals',
      (c) => GoalsPlugin(terminal: c.terminal),
      cli: goalsCli,
      operations: goalsOperations,
      description:
          'Tracks an active goal and its progress across turns, with optional token budgets.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/tasks',
      (c) => TasksPlugin(terminal: c.terminal),
      description:
          'Maintains a queue of follow-up tasks distinct from the plan, and auto-advances when the current task completes.',
      live: true,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/auto-compact',
      (c) => CompactionPlugin(
        terminal: c.terminal,
        canCompact: () => !(c.contextLoaded?.call() ?? false),
      ),
      description:
          'Summarizes older conversation history when context grows large to make room for more work.',
      live: true,
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ToolSessionSource>(
      'tina/context',
      dependency: toolProvider,
      provides: [_workingContext],
      settings: [contextBudgetSetting, contextResponseReserveSetting],
      create: (c, _) => ContextPlugin.sessionMirror(
        readResponseReserveTokens: () =>
            c.settings?.read(contextResponseReserveSetting).value ??
            defaultContextResponseReserveTokens,
        readBudgetTokens: () =>
            c.settings?.read(contextBudgetSetting).value ??
            defaultContextBudgetTokens,
        // The mirror rides the sandbox's file grants; a composition
        // without them (the wasm-shaped leg) mounts the context
        // plugin without the grant hook — absence skips, never throws.
        onMirrorReady: c.capability<ToolsPluginSurface>() == null
            ? null
            : (file) => c
                .capability<ToolsPluginSurface>()!
                .sandbox
                .grants
                .rememberExact(file.resolveSymbolicLinksSync()),
      ),
      description:
          'Experimental: lets the agent edit its working conversation through a temporary file. Preserves the original log and pauses automatic and manual compaction while loaded. Changes require restart.',
      live: false,
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ContextPlugin>(
      'tina/context-tui',
      dependency: _workingContext,
      create: (c, _) => PresentationPlugin<void>(
        id: 'tina/context-tui',
        source: null,
        commands: [
          Command(
            name: 'context',
            description: 'inspect accepted working context and edits',
            allowWhileRunning: true,
            handler: (_) => c.terminal.writeln(
              'The context viewer requires the interactive console.',
            ),
          ),
        ],
      ),
      description:
          'Adds /context to inspect accepted working messages, estimated tokens, pending file edits and the latest accepted changes. Requires tina/context.',
      live: true,
    ),
    PluginDefinition.dependingOn2<
      SessionPluginContext,
      ToolSessionSource,
      ModelAccess
    >(
      'tina/subagents',
      first: toolProvider,
      second: modelAccess,
      settings: subagentSettings,
      create: (c, parentTools, models) => SubagentsPlugin(
        config: SubagentsConfig(
          maxDepth: c.limits.childDepth,
          maxConcurrency: c.limits.childConcurrency,
          tokenBudget: 0,
        ),
        // The swarm gate: a channel: true spawn needs a started chat.
        // The file is the truth — the same existence probe the channel
        // plugin resumes through.
        channelExists: (scope) =>
            defaultChannelStoreExists(c.workingDirectory, scope),
        configFor: () => SubagentsConfig(
          maxDepth: c.currentLimits.childDepth,
          maxConcurrency: c.currentLimits.childConcurrency,
          tokenBudget: 0,
        ),
        sessionFactory: standardChildFactory(
          parentTools: parentTools,
          providerFactory: models.childProvider,
          model: c.model,
          currentModel: c.currentModel,
          // The active profile's subagent leg, read at spawn: children run
          // on it when set, otherwise on the parent's current model.
          subagentModel: c.subagentModel,
          // The base child plugin set (sub-agent mode): no channel
          // plugin — an independent child never sees the group chat.
          childPlugins: (plugin) => [
            const SystemInstructionPlugin(),
            if (c.openStore != null)
              PersistencePlugin(openStore: c.openStore! as SessionStoreOpener),
          ],
          // Swarm mode (channel: true): the child joins the PARENT's
          // chat (the session's group chat) as role `subagent` — a
          // child never spawns, so the chat's member tree is one level
          // deep. The launch gate already proved the chat exists.
          channelChildPlugins: (plugin) => [
            ChannelPlugin(
              openStore: (scope) =>
                  openDefaultChannelStore(c.workingDirectory, scope),
              chatExists: (scope) =>
                  defaultChannelStoreExists(c.workingDirectory, scope),
              chatSessionId: plugin.parent.id,
              role: 'subagent',
              humanName: defaultHumanName(Platform.environment),
              // Same non-fatal rule as the main agent's chat.
              terminal: c.terminal,
            ),
          ],
        ),
        history: c.openStore != null
            ? _StoreHistory(c.openStore! as SessionStoreOpener)
            : null,
      ),
      description:
          'Lets the agent delegate work to child sessions with bounded '
          'depth and concurrency. Two spawn modes: sub-agent (default — '
          'independent, no group chat) and swarm (channel: true — the '
          'child joins the session\'s group chat as a participant).',
      live: false,
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/file-resources',
      (c) => FileResourcesPlugin(
        config: FileResourcesConfig(
          directory: Directory('${c.workingDirectory}/.tina/skills').path,
          heading: '## Skills',
        ),
      ),
      description:
          'Reads skill folders from the workspace and makes their instructions available to the agent.',
      live: true,
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ModePolicySource>(
      'tina/web-search',
      dependency: modePolicySource,
      settings: [webSearchSetting],
      create: (c, source) {
        final backend = BraveSearchBackend(
          keyFrom: () => Platform.environment['BRAVE_SEARCH_API_KEY'] ?? '',
        );
        return WebSearchPlugin(
          backend: backend,
          defaultCount: c.settings?.read(webSearchSetting).value ?? 5,
          // The tool's network ask rides the session's mode policy —
          // the same channel as every other external access — so a
          // Remember… answer is stored and re-checked like the rest.
          authorize: (host, query) async {
            final decision = await source.modePolicy.request(
              operation: 'web search',
              target: query,
              reason: 'Search $host for this query?',
              context: {
                'permission_scope': 'network',
                'authorization_identity': '$host/web_search',
                'required_permissions': ['network'],
              },
            );
            return switch (decision) {
              ApprovalDecision.allow ||
              ApprovalDecision.allowAlways ||
              ApprovalDecision.allowWorkspace ||
              ApprovalDecision.allowGlobal => true,
              _ => false,
            };
          },
        );
      },
      description:
          'Lets the agent search the web with the web_search tool. Requires BRAVE_SEARCH_API_KEY; each search asks permission through the current approval mode.',
      live: true,
    ),
  ],
);

/// A [SubagentHistorySource] backed by the session store: lists every stored
/// session and its last assistant text, so the sub-agents plugin can
/// resurrect previously-launched children after a resume.
final class _StoreHistory implements SubagentHistorySource {
  _StoreHistory(this._open);

  final SessionStoreOpener _open;

  @override
  Map<String, String?> storedSessions() {
    final store = _open();
    try {
      final out = <String, String?>{};
      for (final session in store.list()) {
        out[session.id] = _lastAssistantText(store.readEntries(session.id));
      }
      return out;
    } finally {
      store.close();
    }
  }

  /// The last assistant message's text, or null when the session never
  /// produced an assistant message.
  static String? _lastAssistantText(List<SessionEntry> entries) {
    String? last;
    for (final entry in entries) {
      if (entry is MessageAppendedEntry) {
        final text = [
          for (final b in entry.message.content.whereType<TextBlock>()) b.text,
        ].join();
        if (text.isNotEmpty) last = text;
      }
    }
    return last;
  }
}


/// The answer cache's query string for a process-runner search: the
/// program name plus its arguments — the terms the cache matches over
/// (content words; stop words dropped inside the cache).
String _query(String program, List<String> arguments) =>
    '$program ${arguments.join(' ')}';

