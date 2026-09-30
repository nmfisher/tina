import 'dart:async';
import 'package:tina_host/tina_host.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'limits.dart';

/// A configured endpoint. All sessions using its key share the launch gate.
final class ProviderTarget {
  const ProviderTarget(
      {required this.id,
      required this.create,
      this.minInterval = Duration.zero,
      this.maxConcurrent = 4,
      this.gateKey});
  final String id;
  final String? gateKey;
  final LlmProvider Function() create;
  final Duration minInterval;
  final int maxConcurrent;
}

/// Policy is a plugin; the loop only sees ordinary providers and turn hooks.
final class ProviderPolicyPlugin extends AgentPlugin implements ModelAccess {
  ProviderPolicyPlugin(
      {required this.targets, this.limits = const RequestLimits()})
      : _globalGate = LaunchGate(
            interval: limits.requestsPerMinute == 0
                ? Duration.zero
                : Duration(
                    microseconds: (60000000 / limits.requestsPerMinute).ceil()),
            maxConcurrent: 0);
  final List<ProviderTarget> Function(String model) targets;
  final RequestLimits limits;
  final _gates = <String, LaunchGate>{};
  final LaunchGate _globalGate;
  final _main = _Spend();
  final _global = _Spend();
  final _providers = <_PolicyProvider>{};
  int _configurationRevision = 0;

  /// Rebuild endpoint clients before their next request without losing spend
  /// or interrupting an existing response. The targets callback reads config.
  void refreshConfiguration() => _configurationRevision++;

  /// Reported provider spend, including calls in the current turn.
  int get sessionTokens => _main.total;
  int get sessionEstimatedTokens => _main.estimated;
  int get globalTokens => _global.total;
  int get globalEstimatedTokens => _global.estimated;
  AgentLoop? _loop;
  String _turnId = '';

  int _rotation = 0;
  bool _closed = false;
  @override
  String get id => 'tina/providers';
  @override
  int get order => 0;
  @override
  void onInput(TurnContext c) {
    _main.turn = 0;
    _turnId = c.input.id;
  }

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    final recordedTurns = <String>{};
    for (final entry in loop.log.whereType<UsageRecordedEntry>()) {
      if (!entry.child) recordedTurns.add(entry.turnId);
      _add(entry.child ? _Spend() : _main, _tokens(entry.usage),
          entry.estimatedTokens);
    }
    for (final entry in loop.log.whereType<TurnEndedEntry>()) {
      if (!recordedTurns.contains(entry.turnId)) {
        _add(_main, _tokens(entry.usage), 0);
      }
    }
  }

  LlmProvider mainProvider(String model) => _build(model, _main, false);
  LlmProvider childProvider(String model) => _build(model, _Spend(), true);
  LlmProvider _build(String model, _Spend spend, bool child) {
    if (_closed) throw StateError('provider policy is closed');
    final choices = targets(model);
    if (choices.isEmpty)
      throw ArgumentError('provider pool must contain a member');
    final provider = _PolicyProvider(model, this, choices, spend, child);
    _providers.add(provider);
    return provider;
  }

  String? _refusal(_Spend spend, bool child, int inputEstimate) {
    final cap = child ? limits.childTokens : limits.sessionTokens;
    if (limits.globalTokens > 0 && _global.combined >= limits.globalTokens)
      return 'global token budget exhausted';
    if (cap > 0 && spend.combined >= cap)
      return '${child ? 'subagent' : 'session'} token budget exhausted';
    if (!child && limits.turnTokens > 0 && spend.turn >= limits.turnTokens)
      return 'turn token budget exhausted';
    if (limits.requestTokens > 0 && inputEstimate > limits.requestTokens)
      return 'estimated request input ($inputEstimate tokens) exceeds max_request_tokens (${limits.requestTokens})';
    return null;
  }

  static int _tokens(EntryUsage u) =>
      u.inputTokens +
      u.outputTokens +
      u.cacheCreationInputTokens +
      u.cacheReadInputTokens;

  void _add(_Spend spend, int measured, int estimated) {
    spend.total += measured;
    spend.estimated += estimated;
    spend.turn += measured + estimated;
    _global.total += measured;
    _global.estimated += estimated;
  }

  void _book(_Spend spend, bool child, String turnId, TokenUsage usage) {
    final value = EntryUsage.fromTokens(usage);
    final estimated = usage.estimated ? _tokens(value) : 0;
    final measured = usage.estimated ? const EntryUsage() : value;
    _add(spend, _tokens(measured), estimated);
    _loop?.recordUsage(UsageRecordedEntry(
        turnId: turnId,
        usage: measured,
        estimatedTokens: estimated,
        child: child,
        at: DateTime.now().toUtc().toIso8601String()));
  }

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    for (final provider in _providers.toList()) {
      provider.close();
    }
    for (final gate in _gates.values) {
      gate.close();
    }
    _globalGate.close();
  }
}

final class _Spend {
  int total = 0;
  int estimated = 0;
  int get combined => total + estimated;
  int turn = 0;
}

final class _PolicyProvider extends LlmProvider {
  _PolicyProvider(
      super.model, this.policy, this.targets, this.spend, this.child) {
    _configurationRevision = policy._configurationRevision;
    try {
      for (final target in targets) {
        _members.putIfAbsent(target.id, target.create);
      }
    } catch (_) {
      for (final member in _members.values) {
        member.close();
      }
      rethrow;
    }
  }
  final ProviderPolicyPlugin policy;
  List<ProviderTarget> targets;
  late int _configurationRevision;
  final _Spend spend;
  final bool child;
  final _members = <String, LlmProvider>{};
  final _cancellations = <void Function()>{};
  bool _closed = false;

  void _refreshConfiguration() {
    if (_configurationRevision == policy._configurationRevision ||
        _cancellations.length > 1) return;
    final nextTargets = policy.targets(model);
    if (nextTargets.isEmpty) throw StateError('provider pool has no members');
    final nextMembers = <String, LlmProvider>{};
    try {
      for (final target in nextTargets) {
        nextMembers.putIfAbsent(target.id, target.create);
      }
    } catch (_) {
      for (final member in nextMembers.values) {
        member.close();
      }
      rethrow;
    }
    for (final member in _members.values) {
      member.close();
    }
    _members
      ..clear()
      ..addAll(nextMembers);
    targets = nextTargets;
    _configurationRevision = policy._configurationRevision;
  }

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final cancelled = Completer<void>();
    StreamSubscription<StreamEvent>? upstream;
    void Function()? release;
    var live = true;
    void Function()? settleActive;
    final turnId = policy._turnId;
    void cancel() {
      if (!live) return;
      live = false;
      try {
        settleActive?.call();
      } finally {
        cancelled.complete();
        release?.call();
        release = null;
        unawaited(upstream?.cancel().catchError((Object _) {}));
      }
    }

    late StreamController<StreamEvent> output;
    Future<void> run() async {
      try {
        // A running stream keeps its original clients; subsequent requests pick
        // up saved configuration, including requests within a multi-step turn.
        _refreshConfiguration();
        final targets = this.targets;
        final estimate = (utf8
                    .encode(jsonEncode([
                      system,
                      messages.map((m) => m.toJson()).toList(),
                      tools
                          .map((t) => [t.name, t.description, t.inputSchema])
                          .toList()
                    ]))
                    .length /
                4)
            .ceil();
        final start = policy._rotation++ % targets.length;
        // At most one extra attempt for a response that produced only reasoning.
        var recovered = false;
        var recoveryInstruction = '';
        var attempts = targets.length;
        for (var attempt = 0; attempt < attempts && live; attempt++) {
          final target = targets[(start + attempt) % targets.length];
          final gate = policy._gates.putIfAbsent(
              target.gateKey ?? target.id,
              () => LaunchGate(
                  interval: target.minInterval,
                  maxConcurrent: target.maxConcurrent));
          if (gate.waiting)
            output.add(StreamNotice('Waiting for ${target.id} request slot…'));
          release = await gate.acquire(cancelled.future);
          if (!live || release == null) return;
          final releaseGlobal =
              await policy._globalGate.acquire(cancelled.future);
          if (!live || releaseGlobal == null) return;
          releaseGlobal();
          final refusal = policy._refusal(spend, child, estimate);
          if (refusal != null) {
            output.add(StreamError(refusal, requiresUserAction: true));
            return;
          }
          final provider = _members.putIfAbsent(target.id, target.create);
          final done = Completer<void>();
          var published = false;
          var reasoned = false;
          var complete = false;
          StreamError? failure;
          var booked = false;
          void settle([TokenUsage? usage]) {
            if (booked) return;
            booked = true;
            policy._book(
                spend,
                child,
                turnId,
                usage ??
                    TokenUsage(
                        inputTokens: estimate,
                        outputTokens: 0,
                        estimated: true));
          }

          settleActive = settle;
          upstream = provider
              .send(
                  system: system + recoveryInstruction,
                  messages: messages,
                  tools: tools)
              .listen((event) {
            if (!live || done.isCompleted) return;
            try {
              if (event is StreamError) {
                settle(event.usage);
                failure = event;
              } else {
                if (event is MessageComplete) {
                  complete = true;
                  settle(event.usage ?? TokenUsage.zero);
                }
                if (event is TextDelta ||
                    event is ToolCallStart ||
                    event is MessageComplete) published = true;
                if (event is ReasoningDelta) reasoned = true;
                output.add(event);
              }
            } catch (error) {
              failure = StreamError('usage recording failed: $error',
                  requiresUserAction: true);
              if (!done.isCompleted) done.complete();
              unawaited(upstream?.cancel().catchError((Object _) {}));
            }
          }, onDone: () {
            if (!done.isCompleted) done.complete();
          }, onError: (Object error) {
            failure = StreamError('provider transport failed: $error',
                transient: true);
            if (!done.isCompleted) done.complete();
          }, cancelOnError: true);
          await Future.any([done.future, cancelled.future]);
          settle();
          settleActive = null;
          release?.call();
          release = null;
          if (!live) return;
          final error = failure ??
              (complete
                  ? null
                  : const StreamError(
                      'provider stream ended without completion',
                      transient: true));
          if (error == null) return;
          if (error.statusCode == 429 || error.statusCode == 503)
            gate.cooldown(error.retryAfter ?? const Duration(seconds: 1));
          final retryable = error.transient ||
              error.statusCode == 429 ||
              (error.statusCode ?? 0) >= 500;
          final recoverable = !published &&
              !error.requiresUserAction &&
              (retryable || error.providerCode == 'output_limit');
          if (recoverable && reasoned && !recovered) {
            recovered = true;
            attempts =
                attempt + 2; // exactly one recovery, regardless of pool size
            if (error.providerCode == 'output_limit') {
              recoveryInstruction =
                  '\nThe previous attempt exhausted its output budget during reasoning. '
                  'Keep reasoning brief and proceed directly to the next tool call or final answer.';
            }
            output.add(const ReasoningEnd(complete: false));
            output.add(StreamNotice(
                '${error.error} Retrying once before any answer or tool call.'));
            continue;
          }
          if (published ||
              error.requiresUserAction ||
              !retryable ||
              attempt + 1 == attempts) {
            output.add(error);
            return;
          }
          output.add(StreamNotice(
              'Pool member ${target.id} failed; trying the next member.'));
        }
      } catch (error) {
        if (live) output.add(StreamError('provider policy failed: $error'));
      } finally {
        try {
          settleActive?.call();
        } catch (error) {
          if (live)
            output.add(StreamError('usage recording failed: $error',
                requiresUserAction: true));
        }
        release?.call();
        release = null;
        _cancellations.remove(cancel);
        if (live) {
          live = false;
          cancelled.complete();
        }
        unawaited(output.close());
      }
    }

    output = StreamController<StreamEvent>(
        onListen: () {
          if (_closed) {
            output.add(const StreamError('provider is closed'));
            unawaited(output.close());
            return;
          }
          _cancellations.add(cancel);
          unawaited(run());
        },
        onCancel: cancel);
    return output.stream;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
    for (final member in _members.values) {
      member.close();
    }
    policy._providers.remove(this);
  }
}

/// FIFO start spacing and concurrency. Cancelled waiters never start work.
final class LaunchGate {
  LaunchGate({this.interval = Duration.zero, this.maxConcurrent = 4});
  final Duration interval;
  final int maxConcurrent;
  final _waiting = <Completer<void Function()?>>[];
  var _active = 0;
  var _next = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _timer;
  bool _closed = false;
  bool get waiting =>
      _waiting.isNotEmpty ||
      DateTime.now().isBefore(_next) ||
      (maxConcurrent > 0 && _active >= maxConcurrent);
  Future<void Function()?> acquire(Future<void> cancelled) {
    if (_closed) return Future.value(null);
    final entry = Completer<void Function()?>();
    _waiting.add(entry);
    unawaited(Future.any([cancelled, entry.future]).then((_) {
      if (!entry.isCompleted) {
        _waiting.remove(entry);
        entry.complete(null);
        _pump();
      }
    }));
    _pump();
    return entry.future;
  }

  void cooldown(Duration delay) {
    final until = DateTime.now()
        .add(Duration(milliseconds: math.min(delay.inMilliseconds, 60000)));
    if (until.isAfter(_next)) _next = until;
    _timer?.cancel();
    _timer = null;
    _pump();
  }

  void _pump() {
    if (_closed ||
        _waiting.isEmpty ||
        (maxConcurrent > 0 && _active >= maxConcurrent)) return;
    final remaining = _next.difference(DateTime.now());
    if (remaining > Duration.zero) {
      _timer ??= Timer(remaining, () {
        _timer = null;
        _pump();
      });
      return;
    }
    final entry = _waiting.removeAt(0);
    _active++;
    _next = DateTime.now().add(interval);
    var released = false;
    entry.complete(() {
      if (released) return;
      released = true;
      _active--;
      _pump();
    });
    _pump();
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    for (final entry in _waiting) {
      entry.complete(null);
    }
    _waiting.clear();
  }
}
