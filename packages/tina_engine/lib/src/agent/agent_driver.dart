import '../llm/message.dart';
import '../llm/provider.dart';
import '../permissions/policy.dart';
import '../permissions/prompt.dart';
import '../runtime/plugin.dart';
import '../tools/tool.dart';
import 'agent.dart';
import 'agent_sink.dart';
import 'pause_gate.dart';
import 'token_budget.dart';
import 'tool_guards.dart';
import 'tool_hooks.dart';

/// The replaceable unit behind the agent loop (the P5 seam): the operations
/// coordinators actually use — one turn, the last abort classification, the
/// identity/model/registry the turn runs under, and compaction — with the
/// [Agent]'s sequencing and persistence guarantees kept in the contract.
///
/// An alternate driver does NOT re-implement tool dispatch: [ToolExecutor]
/// (guards, asker, hooks, observers, the whole policy chain) is inherited from
/// [Agent], and a driver is free (expected, even) to keep delegating tool
/// execution to it. The seam replaces the *loop*, not the tool machinery.
///
/// The contract every implementation must honor:
///
///  * [run] returning normally means the turn is RECORDED: every history
///    mutation the turn performed has been flushed through the agent's
///    write-through persistence observers (when wired), so a caller that
///    observes the return can tear down the store safely. Joining on a run is
///    simply awaiting its [Future].
///  * Cancellation rides the [run] `cancelSignal` exactly as it does for
///    [Agent.run] — completing it aborts the in-flight stream and the turn
///    exits cleanly; the caller never cancels the driver by other means.
///  * A driver does NOT own provider lifecycle. The caller builds the
///    [LlmProvider], hands it in via [AgentDriverRequest.provider], and closes
///    it itself when the turn (or the channel) is done — including on error
///    paths. Drivers must not close the provider on the caller's behalf.
abstract class AgentDriver {
  /// Runs one user turn. The driver may issue several provider calls if tools
  /// are invoked. [cancelSignal], when completed, aborts the current in-flight
  /// stream and exits the turn cleanly. [toolInterruptSignal] and [turnTools]
  /// forward verbatim to the underlying loop (see [Agent.run]).
  ///
  /// Returning means the turn is recorded (the write-through persistence
  /// guarantee above); awaiting this Future is the join.
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  });

  /// Why the last turn stopped abnormally — a budget trip, a provider/API
  /// error, a cut-off stream, the action cap, or max steps. null after a
  /// normal finish (or a cancel). Reset at the top of every [run].
  String? get abortedReason;

  /// The same stop classified by cause, for callers deciding whether a retry
  /// could succeed. Reset alongside [abortedReason].
  AbortedKind get abortedKind;

  /// The resolved system prompt this driver's agent runs under.
  String get system;

  /// The tool registry this driver's agent runs with.
  ToolRegistry get tools;

  /// The provider this driver's agent sends requests to. Mutable so a caller
  /// (e.g. a `/model` swap) can swap the provider instance at runtime; the
  /// agent re-reads it on each [run].
  LlmProvider get provider;
  set provider(LlmProvider value);

  /// Replace (part of) [history] with a summarized user+assistant exchange.
  /// Parameters and semantics forward verbatim to [Agent.compact]; returns
  /// true when the history was actually compacted.
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  });
}

/// Trivial driver: forwards EVERY member verbatim to the wrapped [agent].
/// This is the default implementation behind [DefaultAgentDriverFactory] and
/// the adapter that lets a coordinator hand a plain [Agent] to code that
/// speaks [AgentDriver].
class AgentDriverAdapter implements AgentDriver {
  /// The wrapped agent — every operation below delegates to it.
  final Agent agent;

  const AgentDriverAdapter(this.agent);

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  }) =>
      agent.run(
        history: history,
        userInput: userInput,
        cancelSignal: cancelSignal,
        toolInterruptSignal: toolInterruptSignal,
        turnTools: turnTools,
      );

  @override
  String? get abortedReason => agent.abortedReason;

  @override
  AbortedKind get abortedKind => agent.abortedKind;

  @override
  String get system => agent.system;

  @override
  ToolRegistry get tools => agent.tools;

  @override
  LlmProvider get provider => agent.provider;

  @override
  set provider(LlmProvider value) => agent.provider = value;

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) =>
      agent.compact(
        history,
        preserveRecent: preserveRecent,
        preserveRecentMessages: preserveRecentMessages,
        cancelSignal: cancelSignal,
      );
}

/// The creation inputs a coordinator (today: the sub-agent scheduler) passes
/// when it builds a driver. Plain final fields, const-able: a request is a
/// value, not a builder — the factory decides what to construct from it.
class AgentDriverRequest {
  /// The provider the turn sends requests to. The CALLER owns its lifecycle:
  /// it is built and closed at the call site, never by the driver.
  final LlmProvider provider;

  /// The tool registry the turn runs with.
  final ToolRegistry tools;

  /// Where the turn's output streams.
  final AgentSink sink;

  /// The permission policy tool calls run under.
  final PermissionPolicy policy;

  /// The asker consulted when the policy says `ask` (a coordinator that has no
  /// user passes its auto-deny asker).
  final PermissionAsker asker;

  /// Step ceiling for the loop.
  final int maxSteps;

  /// Per-turn / per-session token caps; null = uncapped.
  final TokenBudget? budget;

  /// Shared pause gate for per-session budget trips; null = legacy abort.
  final PauseGate? pauseGate;

  /// The resolved system prompt (the agent's identity).
  final String system;

  /// Extra deny-preserving guards the built agent runs on every tool call,
  /// appended after the executor's mandatory policy and phase guards. Empty
  /// (the default) = none — every pre-plugin build.
  final List<ToolGuard> executionGuards;

  /// AROUND-execution hooks wrapping each tool's execute call. Empty (the
  /// default) = none.
  final List<ToolExecutionHook> executionHooks;

  /// POST-tool hooks appending verdicts to successful tool results. Empty
  /// (the default) = none.
  final List<ToolResultHook> resultHooks;

  /// Observation-only hooks notified at the toolStart/toolOutput/toolComplete
  /// points. Empty (the default) = none.
  final List<ToolObserver> observers;

  const AgentDriverRequest({
    required this.provider,
    required this.tools,
    required this.sink,
    required this.policy,
    required this.asker,
    required this.maxSteps,
    required this.budget,
    required this.pauseGate,
    required this.system,
    this.executionGuards = const [],
    this.executionHooks = const [],
    this.resultHooks = const [],
    this.observers = const [],
  });
}

/// Builds a driver from the coordinator's request. A profile mounts a
/// replacement via [driverPlugin] / [agentDriverFactoryServiceKey]; the
/// coordinator consults the factory (when wired) instead of constructing an
/// [Agent] inline, without any other change to the coordinator.
abstract class AgentDriverFactory {
  AgentDriver create(AgentDriverRequest request);
}

/// The default factory: wraps a plain [Agent] — built from the request
/// verbatim — in an [AgentDriverAdapter]. This reproduces the historical
/// inline build exactly (same wiring, same asker the request carries), so an
/// absent replacement factory is byte-identical to the pre-driver behavior.
class DefaultAgentDriverFactory implements AgentDriverFactory {
  const DefaultAgentDriverFactory();

  @override
  AgentDriver create(AgentDriverRequest request) => AgentDriverAdapter(Agent(
        provider: request.provider,
        tools: request.tools,
        sink: request.sink,
        policy: request.policy,
        asker: request.asker,
        maxSteps: request.maxSteps,
        budget: request.budget,
        pauseGate: request.pauseGate,
        system: request.system,
        executionGuards: request.executionGuards,
        executionHooks: request.executionHooks,
        resultHooks: request.resultHooks,
        toolObservers: request.observers,
      ));
}

/// Service key under which a profile's replacement [AgentDriverFactory] is
/// mounted in a plugin scope.
final ServiceKey<AgentDriverFactory> agentDriverFactoryServiceKey =
    ServiceKey<AgentDriverFactory>('tina.engine.agent_driver_factory');

/// A plugin that mounts [factory] as the agent driver factory under
/// [agentDriverFactoryServiceKey] (id `tina.engine.driver`). A profile adds
/// this descriptor to replace how the agent loop is built without editing the
/// coordinator that consumes it. The plugin's root object IS the factory: the
/// runtime binds every `provides` key to it, so the scope lookup returns
/// [factory] directly.
PluginDescriptor driverPlugin(AgentDriverFactory factory) => PluginDescriptor(
      id: 'tina.engine.driver',
      provides: <ServiceKey>[agentDriverFactoryServiceKey],
      factory: FnPluginFactory((_) => factory),
    );
