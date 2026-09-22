import 'dart:async';
import 'dart:convert';

import '../llm/message.dart';
import '../runtime/invocation.dart';
import '../runtime/plugin.dart';
import '../tools/tool.dart';
import '../tools/tool_input.dart';

/// Invocation runs once per submitted/delegated turn; request runs before each
/// model send (including transport retries); compact identifies summary sends.
enum AgentStage { invocation, request, compact }

/// Invocation changes become the admitted user message. Request changes below
/// are ephemeral and never rewrite the durable conversation.
final class AgentInput {
  final String text;
  final String system;
  const AgentInput({required this.text, required this.system});
  AgentInput copyWith({String? text, String? system}) =>
      AgentInput(text: text ?? this.text, system: system ?? this.system);
}

/// An isolated model request. Plugins can replace messages/instructions and
/// narrow the advertised tools, but cannot add or redefine executable tools.
final class AgentRequest {
  final String system;
  final List<Message> messages;
  final List<ToolSchema> tools;
  AgentRequest(
      {required this.system,
      required Iterable<Message> messages,
      required Iterable<ToolSchema> tools})
      : messages = snapshotMessages(messages),
        tools = List.unmodifiable(tools.map((tool) => ToolSchema(
              name: tool.name,
              description: tool.description,
              inputSchema: asDeepUnmodifiable(tool.inputSchema),
            )));
  void validateTools(List<ToolSchema> available) {
    final names = <String>{};
    for (final tool in tools) {
      final same = available.any((original) =>
          original.name == tool.name &&
          original.description == tool.description &&
          jsonEncode(original.inputSchema) == jsonEncode(tool.inputSchema));
      if (!same || !names.add(tool.name)) {
        throw const AgentMiddlewareError(
            'Middleware cannot add or redefine tools.');
      }
    }
  }

  AgentRequest copyWith(
          {String? system,
          Iterable<Message>? messages,
          Iterable<ToolSchema>? tools}) =>
      AgentRequest(
          system: system ?? this.system,
          messages: messages ?? this.messages,
          tools: tools ?? this.tools);
}

List<Message> snapshotMessages(Iterable<Message> messages) => List.unmodifiable(
      messages.map((message) => Message(
            role: message.role,
            content: List.unmodifiable(message.content.map((block) =>
                block is ToolUseBlock
                    ? ToolUseBlock(
                        id: block.id,
                        name: block.name,
                        input: asDeepUnmodifiable(block.input),
                        argumentsParseError: block.argumentsParseError)
                    : block)),
            reasoning: List.unmodifiable(message.reasoning),
          )),
    );

enum AgentAction { next, reply, stop }

/// A terminal reply is recorded by the runtime. To redirect, a plugin can
/// await another component through existing invocation services and return its
/// reply. No raw driver, provider or mutable transcript is given to middleware.
final class AgentDecision<T> {
  final AgentAction action;
  final T? value;
  final String? text;
  const AgentDecision.next(T this.value)
      : action = AgentAction.next,
        text = null;
  const AgentDecision.reply(String this.text)
      : action = AgentAction.reply,
        value = null;
  const AgentDecision.stop()
      : action = AgentAction.stop,
        value = null,
        text = null;
}

/// One boundary's lifetime. Capture this signal for async work: reading a zone
/// later is not a substitute for keeping the original cancellation context.
final class AgentContext {
  final AgentStage stage;
  final String cwd;
  final bool loadProjectContext;
  final String model;
  final int step;
  final int attempt;
  final List<Message> history;
  final Invocation? invocation;
  Component? get agent => invocation?.component;
  final _stop = Completer<void>();
  bool get isCancelled => _stop.isCompleted || invocation?.isCancelled == true;
  Future<void> get cancelSignal => _stop.future;

  AgentContext({
    required this.stage,
    required this.cwd,
    required this.loadProjectContext,
    required this.model,
    Iterable<Message> history = const [],
    this.step = 0,
    this.attempt = 0,
    Future<void>? cancelSignal,
  })  : invocation = InvocationContext.current?.invocation,
        history = snapshotMessages(history) {
    final signal =
        InvocationContext.current?.stopSignal(cancelSignal) ?? cancelSignal;
    signal?.then((_) => close(), onError: (Object _) => close());
  }

  void check() {
    if (isCancelled)
      throw const InvocationCancelled('Agent preparation cancelled');
  }

  Future<void> ready() async {
    await Future<void>.value();
    check();
    if (invocation != null) {
      await Future.any(
          [invocation!.ready(), cancelSignal.then((_) => check())]);
    }
    check();
  }

  Future<T> wait<T>(FutureOr<T> Function() work, Duration timeout) async {
    await ready();
    final value = await Future.any<T>([
      Future<T>.sync(work),
      cancelSignal.then<T>((_) => throw const InvocationCancelled()),
    ]).timeout(timeout);
    await ready();
    return value;
  }

  /// Hosts close the boundary even on success. Plugins must join work needed
  /// for their decision; detached work cannot modify a request later.
  void close() {
    if (!_stop.isCompleted) _stop.complete();
  }
}

abstract class AgentMiddleware implements Component {
  Duration get timeout => const Duration(seconds: 30);
  FutureOr<AgentDecision<AgentInput>> beforeInvocation(
          AgentContext context, AgentInput input) =>
      AgentDecision.next(input);
  FutureOr<AgentDecision<AgentRequest>> beforeRequest(
          AgentContext context, AgentRequest request) =>
      AgentDecision.next(request);
}

class AgentMiddlewareError implements Exception {
  final String message;
  const AgentMiddlewareError(this.message);
  @override
  String toString() => message;
}

/// A prepared decision still belongs to its original registrations. Check at
/// dispatch, after any host awaits, so removing a plugin revokes stale work.
final class AgentPreparation<T> {
  final AgentDecision<T> decision;
  final void Function() check;
  const AgentPreparation(this.decision, this.check);
}

/// Live, parent-first contributions in registration order. It is safe to keep
/// this pipeline across turns: additions/removals are observed at each boundary.
class AgentMiddlewarePipeline {
  final PluginScope? scope;
  final List<AgentMiddleware> middleware;
  AgentMiddlewarePipeline(
      {this.scope, Iterable<AgentMiddleware> middleware = const []})
      : middleware = List.unmodifiable(middleware);

  List<({PluginScope scope, Contribution entry})> _bindings() {
    final scopes = <PluginScope>[];
    for (var current = scope; current != null; current = current.parent) {
      scopes.insert(0, current);
    }
    return [
      for (final current in scopes)
        for (final entry in current.contributions)
          if (entry.contribution is AgentMiddleware)
            (scope: current, entry: entry)
    ];
  }

  Future<AgentPreparation<AgentInput>> beforeInvocation(
          AgentContext context, AgentInput input) =>
      _prepare(context, input,
          (plugin, value) => plugin.beforeInvocation(context, value));
  Future<AgentPreparation<AgentRequest>> beforeRequest(
          AgentContext context, AgentRequest request) =>
      _prepare(context, request,
          (plugin, value) => plugin.beforeRequest(context, value));

  Future<AgentPreparation<T>> _prepare<T>(AgentContext context, T input,
      FutureOr<AgentDecision<T>> Function(AgentMiddleware, T) invoke) async {
    final bindings = _bindings();
    void check() {
      context.check();
      if (scope != null && !scope!.isAdmitting)
        throw const InvocationCancelled('Plugin scope closed');
      final now = _bindings();
      if (now.length != bindings.length ||
          Iterable<int>.generate(now.length).any((i) =>
              !now[i].scope.isAdmitting ||
              !identical(now[i].entry, bindings[i].entry))) {
        throw const AgentMiddlewareError(
            'Agent middleware changed during preparation; retry.');
      }
    }

    final changed = Completer<AgentDecision<T>>();
    final subscriptions = <StreamSubscription<void>>[];
    for (var current = scope; current != null; current = current.parent) {
      subscriptions.add(current.changes.listen((_) {
        try {
          check();
        } catch (e, st) {
          if (!changed.isCompleted) changed.completeError(e, st);
        }
      }));
    }
    // Observe revocation even when it races the gap between callbacks.
    changed.future.ignore();
    try {
      await context.ready();
      check();
      var decision = AgentDecision<T>.next(input);
      final plugins = [
        ...middleware,
        ...bindings.map((b) => b.entry.contribution as AgentMiddleware)
      ];
      for (final plugin in plugins) {
        try {
          if (plugin.timeout <= Duration.zero)
            throw const AgentMiddlewareError('Invalid middleware timeout');
          decision = await context.wait(
              () => Future.any([
                    Future.sync(() => invoke(plugin, decision.value as T)),
                    changed.future,
                  ]),
              plugin.timeout);
        } on InvocationCancelled {
          rethrow;
        } on AgentMiddlewareError {
          rethrow;
        } on TimeoutException {
          throw AgentMiddlewareError(
              'Agent middleware ${plugin.id} timed out.');
        } catch (_) {
          throw AgentMiddlewareError('Agent middleware ${plugin.id} failed.');
        }
        check();
        if (decision.action != AgentAction.next) break;
      }
      return AgentPreparation(decision, check);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }
}
