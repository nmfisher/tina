/// The loop. One file. Five steps, top to bottom:
///
/// 1. take the input
/// 2. build the request
/// 3. call the model
/// 4. run the tool calls
/// 5. append the results, and repeat from step 2 until the model asks for
///    no tools
///
/// The loop owns an **append-only log** (`tina_core`'s session entries) and
/// is its only writer. Every turn appends its entries — turn started, the
/// input as typed, one entry per plugin rewrite naming the plugin, one per
/// message, turn ended with the stop reason and the usage the providers
/// reported — and publishes each entry to the listeners (a store, a UI).
/// There is no transcript list beside it: the messages a request carries
/// are **derived per request** from the log via `deriveSession`, with the
/// turn being written included and every abandoned turn left out.
///
/// Plugins own decisions, made by writing to the [TurnContext] they are
/// handed — the loop copies the context before every plugin call, hands
/// the copy over, and keeps the copy the call wrote, so a plugin that
/// throws has its writes dropped and the turn continues. A plugin that
/// throws has its entries dropped too: entry appends happen on the loop's
/// side of the phase boundary, after the writes are kept.
///
/// Value types (Message, ToolSchema, ToolUse, ToolResult, stream events)
/// come from `tina_core`; the model boundary is its streaming
/// `LlmProvider.send`.
library;

import 'dart:async' show StreamController, StreamSubscription, unawaited;
import 'dart:collection';

import 'package:tina_core/tina_core.dart';

import 'context.dart';
import 'model.dart';
import 'plugin.dart';
import 'tool_execution.dart';

/// Why an entry reached a listener: [LogEvent.appended] as it landed (in
/// order, exactly once per entry), [LogEvent.replay] when a listener
/// subscribes and receives the log that already exists.
enum LogEvent { appended, replay }

String _now() => DateTime.now().toUtc().toIso8601String();

TurnStopReason _turnReason(StopReason r) =>
    TurnStopReason.values.byName(r.name);

final class _LogListener {
  _LogListener(this.id, this.onEntry);
  final int id;
  final void Function(SessionEntry entry, LogEvent event) onEntry;
}

/// The agent loop.
final class AgentLoop {
  AgentLoop({
    required LlmProvider provider,
    required List<AgentPlugin> plugins,
    this.maxStepsPerTurn = 16,
    SessionSettings settings = const SessionSettings(),
    List<SessionEntry> seedLog = const [],
  })  : _provider = provider,
        _settings = settings {
    _log.addAll(seedLog);
    _seq = _log.length;
    for (final p in plugins) {
      addPlugin(p);
    }
  }

  final LlmProvider _provider;
  final int maxStepsPerTurn;

  /// The session's provider, read-only. Compaction needs it: the summary
  /// is one extra request on the provider the turn already uses — the
  /// plugin does not build its own and never closes this one.
  LlmProvider get provider => _provider;

  /// Plugins in registration order. A duplicate id throws here.
  final LinkedHashMap<String, AgentPlugin> _byId = LinkedHashMap();

  /// One token per turn; contexts retain their token after the turn ends.
  CancelToken _cancel = CancelToken();
  bool _running = false;

  /// The session log — the loop's only conversation state. Append-only;
  /// `_seq` is the next entry's position, so a store that persists by
  /// position can detect a gap (corruption) and can never delete.
  final List<SessionEntry> _log = [];
  int _seq = 0;

  /// The per-session settings derive consults. The mode moves through
  /// [set mode]; each move appends a [ModeChangedEntry].
  SessionSettings _settings;

  final List<_LogListener> _listeners = [];
  int _nextListenerId = 0;

  /// True between [runTurn]'s start and its single exit; compaction is a
  /// between-turns operation and refuses to run mid-turn.
  bool _inTurn = false;

  /// Whether a foreground turn is constructing or consuming model requests.
  bool get inTurn => _inTurn;
  bool get running => _running;

  /// Run order: ascending [AgentPlugin.order], ties broken by id, so the
  /// sequence is the same every run.
  List<AgentPlugin> _inOrder() {
    final list = _byId.values.toList()
      ..sort((a, b) => a.order != b.order
          ? a.order.compareTo(b.order)
          : a.id.compareTo(b.id));
    return list;
  }

  /// Register a plugin. A duplicate id throws.
  void addPlugin(AgentPlugin plugin) {
    validatePluginId(plugin.id);
    if (_byId.containsKey(plugin.id)) {
      throw ArgumentError('duplicate plugin id: ${plugin.id}');
    }
    _byId[plugin.id] = plugin;
  }

  /// Remove a plugin. Dispatch re-checks liveness.
  void removePlugin(String id) {
    _byId.remove(id);
    for (final name in _executorOwners.keys
        .where((name) => _executorOwners[name] == id)
        .toList()) {
      _executors.remove(name);
      _executorOwners.remove(name);
    }
    for (final handle in _listenerOwners.keys
        .where((handle) => _listenerOwners[handle] == id)
        .toList()) {
      unsubscribe(handle);
    }
  }

  String? _mounting;
  final _executorOwners = <String, String>{};
  final _listenerOwners = <int, String>{};

  /// Track registrations made by the plugin, including partial mounts.
  void mountPlugin(AgentPlugin plugin) {
    if (_mounting != null) throw StateError('nested plugin mount');
    _mounting = plugin.id;
    try {
      plugin.mountOn(this);
    } finally {
      _mounting = null;
    }
  }

  /// Give a tool its executor. Executors are not part of [ToolSchema]: they
  /// run in-process and return the full [ToolResult] — content plus flags —
  /// and `afterToolResult` can replace what they returned. An existing
  /// string-returning function wraps with [stringExecutor].
  void registerExecutor(String tool,
          Future<ToolResult> Function(Map<String, Object?>) exec) =>
      registerContextExecutor(tool, (input, _) => exec(input));

  void registerContextExecutor(String tool, ContextToolExecutor exec) {
    final owner = _mounting;
    if (owner != null &&
        _executors.containsKey(tool) &&
        _executorOwners[tool] != owner) {
      throw StateError('executor "$tool" is already registered');
    }
    _executors[tool] = exec;
    if (owner != null) _executorOwners[tool] = owner;
  }

  final Map<String, ContextToolExecutor> _executors = {};

  final _toolActivity = StreamController<ToolActivity>.broadcast(sync: true);

  /// Live execution observations. Results in the log remain authoritative.
  Stream<ToolActivity> get toolActivity => _toolActivity.stream;

  /// The one cancellation path.
  ///
  /// Setting the token is only half of "stop": a turn parked inside the
  /// provider's stream (a slow model, a stalled network) would sit there
  /// until the socket gave up. So [cancel] also closes the stream the
  /// loop is currently awaiting — if one is in flight. Closing from
  /// outside ends an `await for` immediately; the loop's await throws,
  /// the existing catch treats it like any provider error, and the turn
  /// exits through the one [finish] with the cancel already recorded.
  /// No-op when no call is in flight: the flag alone stops the turn at
  /// the next check.
  void cancel(String why) {
    _cancel.cancel(why);
    _modelCall?.close();
  }

  /// The model call in flight, when one is — [cancel] closes it so the
  /// turn does not wait on a provider that will not stop on its own.
  StreamController<StreamEvent>? _modelCall;

  /// The log so far — the loop's truth, read-only. `entry` at position
  /// `i` has `seq == i`; a store keyed by position can detect a gap.
  List<SessionEntry> get log => List.unmodifiable(_log);

  /// The next entry's position. Equals `log.length` between turns.
  int get seq => _seq;

  /// The session's settings (system prompt, mode) as the loop holds them.
  SessionSettings get settings => _settings;

  /// The permission mode now — the setting, or the latest
  /// [ModeChangedEntry]'s word, which is the same thing: setting the mode
  /// appends the entry. Derive reads the log, not this field.
  String get mode => _settings.mode;

  set mode(String newMode) {
    _settings =
        SessionSettings(systemPrompt: _settings.systemPrompt, mode: newMode);
    _append(ModeChangedEntry(mode: newMode, at: _now()));
  }

  /// Listen to the log. The listener first receives every entry already
  /// in the log as [LogEvent.replay], in order, then each new entry as it
  /// lands as [LogEvent.appended] — which is the hook a persistence store
  /// appends from and a UI renders from. Returns a handle for
  /// [unsubscribe]. Entry payloads are immutable; listeners may keep them.
  int subscribe(void Function(SessionEntry entry, LogEvent event) onEntry) {
    final id = _nextListenerId++;
    if (_mounting != null) _listenerOwners[id] = _mounting!;
    _listeners.add(_LogListener(id, onEntry));
    for (final e in _log) {
      onEntry(e, LogEvent.replay);
    }
    return id;
  }

  void unsubscribe(int handle) {
    _listeners.removeWhere((l) => l.id == handle);
    _listenerOwners.remove(handle);
  }

  /// Append to the log and publish to the listeners. The only write path;
  /// `_seq` is the entry's position, so the store's rows and this list
  /// cannot disagree.
  SessionEntry _append(SessionEntry entry) {
    final stored = entry.withSeq(_seq++);
    _log.add(stored);
    for (final l in List.of(_listeners)) {
      l.onEntry(stored, LogEvent.appended);
    }
    return stored;
  }

  /// The request-shaped view of the log, derived fresh on every call.
  /// Mid-turn this includes the turn being written — the last open turn —
  /// because its messages are what the next request must carry; a
  /// resumed log's older abandoned turns stay out in both cases.
  ///
  /// There is no other copy of the conversation: this list, built from
  /// the log, is what a request is built from.
  DerivedSession derive() =>
      deriveSession(_log, _settings, includePendingTurn: true);

  /// Compact completed history: replace derived-message positions
  /// [from]..[to] (inclusive, as [derive] counts them today) with one
  /// synthetic user message carrying [summary]. Between turns only — the
  /// entry's range must address the list exactly as it stands when it is
  /// appended, and mid-turn that list is about to grow. The dropped text
  /// is gone from the derived view but the log stays append-only: the
  /// [CompactedEntry] records what was replaced.
  void compact(int from, int to, String summary) {
    if (_inTurn) {
      throw StateError('compact between turns, not mid-turn');
    }
    final view = derive();
    if (from < 0 || to < from || to >= view.messages.length) {
      throw RangeError.range(
          to, from, view.messages.length - 1, 'compaction range');
    }
    _append(CompactedEntry(
        replacedFrom: from, replacedTo: to, summary: summary, at: _now()));
  }

  /// Record one piece of plugin orchestration state in the log — the
  /// session's plan today, and any later whole-state blob of the same
  /// shape. The entry **is** the state: the latest one wins in a derive,
  /// so a resume replays it exactly as the running session saw it. Like
  /// [compact], this writes an entry the plugin cannot reach otherwise
  /// (the log's writer is the loop alone) and accepts one mid-turn —
  /// the tool executor that produced the state runs inside a turn, and
  /// a state change is not a message splice: nothing about the request
  /// under construction shifts under it.
  void recordState(SessionEntry entry) => _append(entry);

  /// The end entry appended on a crash path: listener errors on this one
  /// write are suppressed (the original error is what must surface; a
  /// second throw here would hide it), but the write itself happens.
  void _appendCrashEnd(String turnId, EntryUsage usage) {
    final entry = TurnEndedEntry(
        turnId: turnId, reason: TurnStopReason.error, usage: usage, at: _now());
    try {
      _append(entry);
    } catch (_) {
      // the original error outranks this one
    }
  }

  /// The fresh context a turn starts from: the input as it arrived, the
  /// derived view so far, no sections yet, the pinned tools.
  TurnContext _start(Input raw, List<ToolSchema> pinned) => TurnContext(
        _cancel,
        input: raw,
        messages: List.of(derive().messages),
        promptSections: const [],
        pinnedTools: List.of(pinned),
      );

  /// One plugin phase. The copy rule lives here, in one place: each plugin
  /// is handed a copy of the *current* state, and the copy it wrote is
  /// kept. A plugin that throws has its copy dropped — its writes never
  /// arrive, and the next plugin still runs. Entry appends are not plugin
  /// writes: the loop appends from its own side, after a write is kept.
  TurnContext _phase(
      TurnContext ctx, void Function(AgentPlugin p, TurnContext c) body) {
    for (final p in _inOrder()) {
      final copy = ctx.copy();
      try {
        body(p, copy);
      } catch (_) {
        continue; // one bad plugin must not break the turn
      }
      ctx = copy;
    }
    return ctx;
  }

  /// The system prompt: the context's sections joined by a blank line, in
  /// the order they were added. A plugin adds one section, never a whole
  /// prompt; an empty section contributes nothing. With no sections the
  /// prompt is an empty string — the core owns no prompt text.
  static String _joinSections(List<String> sections) => [
        for (final s in sections)
          if (s.isNotEmpty) s,
      ].join('\n\n');

  /// The five steps of one turn, in order, in one pass.
  Future<Outcome> runTurn(Input raw) async {
    if (_running) throw StateError('a turn is already running');
    _running = true;
    try {
      return await _runTurn(raw);
    } finally {
      _running = false;
      _inTurn = false;
      _cancel = CancelToken();
    }
  }

  Future<Outcome> _runTurn(Input raw) async {
    _inTurn = true;
    // ------------------------------------------------------------------
    // Step 1: take the input. The pinned tool set is snapshotted once,
    // from the plugins' `tools` getters, before anything runs.
    // ------------------------------------------------------------------
    final pinnedMap = {
      for (final p in _inOrder())
        for (final t in p.tools) t.name: t
    };
    final ownerOf = {
      for (final p in _inOrder())
        for (final t in p.tools) t.name: p.id
    };
    final pinned = [for (final t in pinnedMap.values) t];
    final turnId = raw.id;
    final appended = <Message>[];
    final requests = <Request>[];
    final responses = <Message>[];
    var usage = const EntryUsage();
    String? changedBy;

    // The turn begins in the log before anything else: the start and the
    // raw input as typed are the two entries no path may skip. Listener
    // errors propagate (a broken store must not be papered over), but the
    // try below still lands the turn's end entry when they do.
    try {
      _append(TurnStartedEntry(turnId: turnId, at: _now()));
      _append(InputRecordedEntry(turnId: turnId, text: raw.text, at: _now()));
    } catch (e) {
      _inTurn = false;
      _appendCrashEnd(turnId, usage);
      rethrow;
    }

    var ctx = _start(raw, pinned);

    // The single exit: record the turn's end in the log, build the
    // outcome, fan out onTurnEnd, return. Every exit — complete,
    // cancelled, provider error, even a loop-internal throw — comes
    // through here, so a started turn always ends in the log.
    Outcome finish(StopReason reason, String detail) {
      _append(TurnEndedEntry(
          turnId: turnId,
          reason: _turnReason(reason),
          usage: usage,
          at: _now()));
      _inTurn = false;
      final outcome = Outcome(
          stopReason: reason,
          messages: List.of(appended),
          modelRequests: [for (final r in requests) r.snapshot()],
          modelResponses: List.of(responses),
          usage: responses.length,
          detail: detail,
          changedBy: changedBy);
      _phase(ctx, (p, c) {
        c.outcome = outcome;
        p.onTurnEnd(c);
      });
      return outcome;
    }

    try {
      // Prompt-section phase, once per turn. The sections the plugins add
      // here are the base; `beforeModelCall` may adjust them per call.
      ctx = _phase(ctx, (p, c) => p.onPrompt(c));
      final baseSections = List.of(ctx.promptSections);

      // Input phase. A rewrite is an assignment to `c.input`; the last
      // rewrite is the one the turn takes — and each one lands in the log
      // naming the plugin, because a rewrite cannot be recomputed later.
      for (final p in _inOrder()) {
        final before = ctx.input;
        final copy = ctx.copy();
        try {
          p.onInput(copy);
        } catch (_) {
          continue; // one bad plugin must not break the turn
        }
        ctx = copy;
        if (ctx.input.text != before.text || ctx.input.id != before.id) {
          changedBy = p.id;
          _append(InputRewrittenEntry(
              turnId: turnId,
              pluginId: p.id,
              text: ctx.input.text,
              at: _now()));
        }
      }
      final user =
          Message(role: Role.user, content: [TextBlock(ctx.input.text)]);
      _append(MessageAppendedEntry(turnId: turnId, message: user, at: _now()));
      appended.add(user);

      // ------------------------------------------------------------------
      // Steps 2–5. Repeat until the model asks for no tools, the turn is
      // cancelled, or the step budget runs out.
      // ------------------------------------------------------------------
      for (var step = 0; step < maxStepsPerTurn; step++) {
        if (_cancel.cancelled) {
          return finish(StopReason.cancelled, 'cancelled: ${_cancel.reason}');
        }

        // Step 2: build the request. The conversation is derived from the
        // log — there is no second list — then the context is refreshed
        // with it and the per-call phase runs, and the request is built
        // from what the context holds afterwards. A plugin that prunes or
        // redacts prunes this request, never the log.
        final derived = derive();
        ctx
          ..messages = List.of(derived.messages)
          ..promptSections = List.of(baseSections)
          ..call = null
          ..toolResult = null
          ..decision = const Decision.allow();
        ctx = _phase(ctx, (p, c) => p.beforeModelCall(c));
        var request = Request(
            systemPrompt: _joinSections(ctx.promptSections),
            messages: List.of(ctx.messages),
            tools: List.of(ctx.pinnedTools));

        // Step 3: call the model. The provider streams: [ToolCallStart]
        // announces each call the model asks for, the text deltas accumulate
        // the answer, and [MessageComplete] carries the final blocks — the
        // tool-use inputs come from there, keyed by the started ids — plus
        // the usage this request booked, summed into the turn's.
        // A [StreamError] ends the turn as StopReason.error, recorded. A
        // provider that throws — at `send` or anywhere in the stream — is
        // caught here: the turn ends the same way, and whatever deltas had
        // already accumulated are kept as the reply, not discarded.
        final starts = <ToolCallStart>[];
        final blocksById = <String, ToolUseBlock>{};
        final deltaText = StringBuffer();
        MessageComplete? completion;
        StreamError? failure;
        Object? thrown;
        // The loop owns the receiving controller so cancellation ends the
        // turn promptly, even if provider cleanup itself is slow.
        final call = StreamController<StreamEvent>();
        StreamSubscription<StreamEvent>? source;
        _modelCall = call;
        if (_cancel.cancelled) {
          unawaited(call.close());
        } else {
          try {
            source = _provider
                .send(
              system: request.systemPrompt,
              messages: request.messages,
              tools: request.tools,
            )
                .listen(
              (event) {
                if (!call.isClosed) call.add(event);
              },
              onError: (Object error, StackTrace trace) {
                if (!call.isClosed) call.addError(error, trace);
                unawaited(call.close());
              },
              onDone: () {
                unawaited(call.close());
              },
            );
          } catch (error, trace) {
            call.addError(error, trace);
            unawaited(call.close());
          }
        }
        try {
          await for (final event in call.stream) {
            if (event is ToolCallStart) {
              starts.add(event);
            } else if (event is TextDelta) {
              deltaText.write(event.text);
            } else if (event is MessageComplete) {
              completion = event;
              final u = event.usage;
              if (u != null) usage += EntryUsage.fromTokens(u);
              for (final b in event.content.whereType<ToolUseBlock>()) {
                blocksById[b.id] = b;
              }
            } else if (event is StreamError) {
              failure = event;
              break;
            }
            // Reasoning deltas and stream notices carry no transcript state.
          }
        } catch (e) {
          thrown = e; // the turn ends below, at the single StreamError exit
        } finally {
          // Cancel delivery now; do not block a turn on a stuck transport's
          // asynchronous cleanup. Late source errors have no consumer.
          unawaited(source?.cancel().catchError((Object _) {}));
        }
        // The call is over — the next step's call, if any, gets its own
        // controller; a [cancel] between calls stops by flag alone.
        _modelCall = null;
        void recordPartialText() {
          if (deltaText.isEmpty) return;
          // Only completed text deltas are retained, never unfinished tool
          // calls. What was shown before interruption survives session resume.
          final partial = Message(
              role: Role.assistant, content: [TextBlock(deltaText.toString())]);
          requests.add(request.snapshot());
          _append(MessageAppendedEntry(
              turnId: turnId, message: partial, at: _now()));
          appended.add(partial);
          responses.add(partial);
        }

        // A cancel that closed the stream mid-call (or raced the setup)
        // ends the turn here: the cancel is the truth, taking precedence
        // over whatever the stream had delivered — never misread as a
        // provider error or as a complete short reply.
        if (_cancel.cancelled) {
          recordPartialText();
          return finish(StopReason.cancelled, 'cancelled: ${_cancel.reason}');
        }
        if (failure != null) {
          recordPartialText();
          return finish(StopReason.error, 'provider error: ${failure.error}');
        }
        if (thrown != null) {
          recordPartialText();
          return finish(StopReason.error, 'provider error: $thrown');
        }
        // A call announced by [ToolCallStart] whose block never arrived via
        // [MessageComplete] has no [ToolUseBlock] in the log: there
        // is no tool_use to pair a result with, and nothing legitimate to
        // dispatch. Dispatching it would fabricate an empty-input call and a
        // successful result for a tool_use that does not exist, and the
        // assistant reply would be an empty message. So — no dispatch, no
        // result, no reply message; the turn ends with the reason recorded.
        // The pairing invariant is untouched: this case creates neither
        // side of the pair.
        final orphans = [
          for (final s in starts)
            if (!blocksById.containsKey(s.id)) s
        ];
        if (orphans.isNotEmpty) {
          return finish(
              StopReason.error,
              'provider stream ended before tool call '
              '${[for (final s in orphans) s.id].join(', ')} completed');
        }
        final blocks = completion?.content ??
            [if (deltaText.isNotEmpty) TextBlock(deltaText.toString())];
        final toolCalls = [
          for (final s in starts)
            ToolUse(id: s.id, name: s.name, input: blocksById[s.id]!.input),
        ];
        final replyText =
            [for (final b in blocks.whereType<TextBlock>()) b.text].join();
        requests.add(request.snapshot());
        final reply = Message(role: Role.assistant, content: blocks);
        _append(
            MessageAppendedEntry(turnId: turnId, message: reply, at: _now()));
        appended.add(reply);
        responses.add(reply);
        if (toolCalls.isEmpty) {
          return finish(StopReason.complete, replyText);
        }

        // Step 4: run the tool calls. Liveness first: a plugin that left
        // mid-turn has its call skipped, not crashed on. Then the guard
        // phase, in order — the first non-allow decision stops the phase and
        // the call is not dispatched (`ask` with no UI resolves to deny).
        // Then the executor; then the result phase, in order, which may
        // replace the result the core records. Attribution (who denied, why)
        // travels in the result's content: the model reads exactly this
        // string.
        for (final call in toolCalls) {
          ToolResult result;
          if (_cancel.cancelled) {
            result = ToolResult('cancelled: ${_cancel.reason}', isError: true);
          } else {
            final owner = ownerOf[call.name];
            if (owner != null && !_byId.containsKey(owner)) {
              result = ToolResult('skipped: plugin $owner left', isError: true);
            } else {
              ctx
                ..call = call
                ..decision = const Decision.allow();
              String? deniedBy;
              for (final p in _inOrder()) {
                final copy = ctx.copy();
                try {
                  p.beforeToolCall(copy);
                } catch (_) {
                  continue; // a throwing guard allows, like any absent one
                }
                ctx = copy;
                if (ctx.decision.kind != DecisionKind.allow) {
                  deniedBy = p.id; // first non-allow decides; later guards
                  break; // do not run
                }
              }
              final decision = ctx.decision;
              final exec = _executors[call.name];
              if (deniedBy != null) {
                result = decision.replacement ??
                    ToolResult(
                        'denied by $deniedBy'
                        '${decision.kind == DecisionKind.ask ? ' (ask-unresolved)' : ''}'
                        ': ${decision.reason}',
                        isError: true);
              } else if (exec == null) {
                result =
                    ToolResult('no executor for ${call.name}', isError: true);
              } else {
                final cancel = _cancel;
                var active = true;
                _toolActivity.add(ToolStarted(call));
                try {
                  var recorded = await exec(
                      call.input,
                      ToolExecutionContext(
                        isCancelled: () => cancel.cancelled,
                        whenCancelled: cancel.whenCancelled,
                        report: (text, {isError = false}) {
                          if (active && !cancel.cancelled && text.isNotEmpty) {
                            _toolActivity
                                .add(ToolOutput(call, text, isError: isError));
                          }
                        },
                      ));
                  ctx.toolResult = recorded;
                  ctx = _phase(ctx, (p, c) => p.afterToolResult(c));
                  recorded = ctx.toolResult ?? recorded;
                  result = recorded;
                } catch (e) {
                  result = ToolResult('tool threw: $e', isError: true);
                } finally {
                  active = false;
                }
                _toolActivity.add(ToolFinished(call, result));
              }
            }
          }

          // Step 5: append the result. Pairing holds even for a cancelled,
          // denied or skipped call: the core writes a result that says so.
          final message = Message(role: Role.user, content: [
            ToolResultBlock(
                toolUseId: call.id,
                content: result.content,
                isError: result.isError),
          ]);
          _append(MessageAppendedEntry(
              turnId: turnId, message: message, at: _now()));
          appended.add(message);
        }

        // The pinning invariant: the live tool set still matches the pinned
        // set. A plugin that left is not a change — its tools became
        // undispatchable, which the liveness check handled. Anything else is.
        final livePinned = {
          for (final name in pinnedMap.keys)
            if (_byId.containsKey(ownerOf[name]!)) name
        };
        final now = {
          for (final p in _inOrder())
            for (final t in p.tools) t.name
        };
        if (now.length != livePinned.length || !now.containsAll(livePinned)) {
          return finish(StopReason.error, 'tools-changed mid-turn');
        }
      }
      return finish(StopReason.error, 'max-steps ($maxStepsPerTurn) exceeded');
    } catch (e) {
      // No path may leave a started turn open in the log, this one
      // included: end it as an error and let the caller see the throw.
      _inTurn = false;
      _appendCrashEnd(turnId, usage);
      rethrow;
    }
  }
}
