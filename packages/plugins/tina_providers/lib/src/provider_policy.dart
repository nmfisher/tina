import 'dart:async';
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
final class ProviderPolicyPlugin extends AgentPlugin {
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
  int _rotation = 0;
  bool _closed = false;
  @override
  String get id => 'tina/providers';
  @override
  int get order => 0;
  @override
  void onInput(TurnContext c) {
    _main.turn = 0;
  }

  @override
  void mountOn(AgentLoop loop) {
    for (final entry in loop.log.whereType<TurnEndedEntry>()) {
      final u = entry.usage;
      _book(
          _main,
          TokenUsage(
              inputTokens: u.inputTokens,
              outputTokens: u.outputTokens,
              cacheCreationInputTokens: u.cacheCreationInputTokens,
              cacheReadInputTokens: u.cacheReadInputTokens));
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
    if (limits.globalTokens > 0 && _global.total >= limits.globalTokens)
      return 'global token budget exhausted';
    if (cap > 0 && spend.total >= cap)
      return '${child ? 'subagent' : 'session'} token budget exhausted';
    if (!child && limits.turnTokens > 0 && spend.turn >= limits.turnTokens)
      return 'turn token budget exhausted';
    if (limits.requestTokens > 0 && inputEstimate > limits.requestTokens)
      return 'estimated request input ($inputEstimate tokens) exceeds max_request_tokens (${limits.requestTokens})';
    return null;
  }

  void _book(_Spend spend, TokenUsage? usage) {
    if (usage == null) return;
    final tokens = usage.inputTokens +
        usage.outputTokens +
        usage.cacheCreationInputTokens +
        usage.cacheReadInputTokens;
    spend.total += tokens;
    spend.turn += tokens;
    _global.total += tokens;
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
  int turn = 0;
}

final class _PolicyProvider extends LlmProvider {
  _PolicyProvider(
      super.model, this.policy, this.targets, this.spend, this.child) {
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
  final List<ProviderTarget> targets;
  final _Spend spend;
  final bool child;
  final _members = <String, LlmProvider>{};
  final _cancellations = <void Function()>{};
  bool _closed = false;

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final cancelled = Completer<void>();
    StreamSubscription<StreamEvent>? upstream;
    void Function()? release;
    var live = true;
    void cancel() {
      if (!live) return;
      live = false;
      cancelled.complete();
      release?.call();
      release = null;
      unawaited(upstream?.cancel().catchError((Object _) {}));
    }

    late StreamController<StreamEvent> output;
    Future<void> run() async {
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
      try {
        for (var attempt = 0; attempt < targets.length && live; attempt++) {
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
          var complete = false;
          StreamError? failure;
          upstream = provider
              .send(system: system, messages: messages, tools: tools)
              .listen((event) {
            if (!live) return;
            if (event is StreamError) {
              policy._book(spend, event.usage);
              failure = event;
            } else {
              if (event is MessageComplete) {
                complete = true;
                policy._book(spend, event.usage);
              }
              if (event is TextDelta ||
                  event is ToolCallStart ||
                  event is MessageComplete ||
                  event is ReasoningEvent) published = true;
              output.add(event);
            }
          }, onDone: () {
            if (!done.isCompleted) done.complete();
          }, onError: (Object error) {
            failure = StreamError('provider transport failed: $error',
                transient: true);
            if (!done.isCompleted) done.complete();
          }, cancelOnError: true);
          await Future.any([done.future, cancelled.future]);
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
          if (published ||
              error.requiresUserAction ||
              !retryable ||
              attempt + 1 == targets.length) {
            output.add(error);
            return;
          }
          output.add(StreamNotice(
              'Pool member ${target.id} failed; trying the next member.'));
        }
      } catch (error) {
        if (live) output.add(StreamError('provider policy failed: $error'));
      } finally {
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
