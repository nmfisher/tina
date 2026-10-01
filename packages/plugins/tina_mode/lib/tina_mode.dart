library;

import 'dart:async';
import 'package:classification/permissions.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'mode.dart';
export 'mode.dart';
export 'package:classification/permissions.dart';

/// Owns permission mode and approval routing. Tools enforce its decisions;
/// a console attachment renders it without introducing terminal dependencies.
abstract interface class ModePolicySource {
  ModePlugin get modePolicy;
}

class ModePlugin extends AgentPlugin implements ModeControl {
  ModePlugin({
    PermissionMode mode = PermissionMode.ask,
    this.terminal,
    this.approvals,
    this.classifier,
  }) : _mode = mode;
  @override
  String get id => 'tina/mode';
  @override
  int get order => 9;
  @override
  PermissionMode get mode => _mode;
  PermissionMode _mode;
  void Function(PluginStateEntry)? _writeState;
  @override
  void mountOn(AgentLoop loop) => mountPolicy(loop, ownerId: id);

  String _stateOwner = 'tina/mode';
  void mountPolicy(AgentLoop loop, {required String ownerId}) {
    _stateOwner = ownerId;
    final state =
        (loop.derive().pluginStates[ownerId] ??
        loop.derive().pluginStates[id])?['permission-mode'];
    if (state != null && state.value != null) {
      if (state.schemaVersion != 1)
        throw FormatException(
          'Unsupported mode state version ${state.schemaVersion}',
        );
      final word = state.value!['mode'];
      final restored = word == 'normal'
          ? PermissionMode.ask
          : parseMode(word is String ? word : '');
      if (restored == null)
        throw FormatException('Unknown saved permission mode: $word');
      mode = restored;
    }
    // Missing historical state retains the configured mode (ask by default).
    _writeState = loop.stateWriter(ownerId);
  }

  final _listeners = <void Function(PermissionMode)>[];
  Completer<void> _changed = Completer<void>();
  final _closedSignal = Completer<void>();
  @override
  set mode(PermissionMode value) {
    if (_mode == value) return;
    _writeState?.call(
      PluginStateEntry.snapshot(
        pluginId: _stateOwner,
        stateKey: 'permission-mode',
        schemaVersion: 1,
        value: {'mode': value.label},
      ),
    );
    _mode = value;
    _callApprovals.clear();
    _changed.complete();
    _changed = Completer<void>();
    for (final listener in _listeners) {
      listener(value);
    }
  }

  void listen(void Function(PermissionMode) listener) =>
      _listeners.add(listener);
  Terminal? terminal;
  ApprovalRequester? approvals;
  PermissionClassifier? classifier;
  TurnContext? _turn;
  ToolUse? _call;
  // One approval covers one invocation, including atomic temp/rename writes.
  // It never survives afterToolResult or a mode change.
  final Map<
    ({String operation, bool humanOnly, String permissions}),
    ApprovalDecision
  >
  _callApprovals = {};
  bool _closed = false;

  static final modeWords = List<String>.unmodifiable(
    PermissionMode.values.map((m) => m.label),
  );
  static PermissionMode? parseMode(String word) {
    for (final mode in PermissionMode.values) {
      if (mode.label == word.trim()) return mode;
    }
    return null;
  }

  static String wordFor(PermissionMode mode) => mode.label;

  @override
  List<Command> get commands => [
    Command(
      name: 'mode',
      description: 'Permission mode: ${modeWords.join(', ')}',
      complete: (prefix) =>
          modeWords.where((m) => m.startsWith(prefix)).toList(),
      handler: (argument) {
        if (argument.trim().isNotEmpty) {
          final selected = parseMode(argument);
          if (selected == null) {
            terminal?.writeln('no mode named ${argument.trim()}');
            return;
          }
          mode = selected;
        }
        terminal?.writeln('mode: ${mode.label}');
      },
    ),
  ];

  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    Map<String, Object?> context = const {},
    ApprovalKind kind = ApprovalKind.permission,
    bool humanOnly = false,
  }) async {
    final turn = _turn;
    bool invalid() =>
        _closed || turn?.cancelled == true || !identical(turn, _turn);
    if (invalid()) return ApprovalDecision.deny;
    final call = _call;
    final requiredPermissions = context['required_permissions'];
    final cacheKey = (
      operation: operation,
      humanOnly: humanOnly,
      permissions: requiredPermissions is Iterable
          ? requiredPermissions.join(',')
          : '',
    );
    final permission = kind == ApprovalKind.permission;
    if (permission && call != null && _callApprovals.containsKey(cacheKey)) {
      return _callApprovals[cacheKey]!;
    }
    String? autoFallback;
    String? autoDenialReason;
    Map<String, Object?> autoDiagnostics = const {};
    if (mode == PermissionMode.auto && permission && !humanOnly) {
      final judge = classifier;
      final result = judge == null
          ? const PermissionJudgment(null, 'not configured')
          : await judge.classify(
              {
                'operation': operation,
                'target': target,
                'reason': reason,
                ...context,
                if (_call != null)
                  'tool': {'name': _call!.name, 'input': _call!.input},
              },
              whenCancelled: Future.any([
                if (turn != null) turn.whenCancelled,
                _changed.future,
                _closedSignal.future,
              ]),
            );
      if (invalid()) return ApprovalDecision.deny;
      autoDiagnostics = result.diagnostics;
      if (result.allow == false) autoDenialReason = result.reason;
      if (mode == PermissionMode.auto && result.allow == true) {
        terminal?.writeln('$operation allowed by classifier: $target');
        // Classifier approvals apply once, never become human session grants.
        if (call != null && identical(call, _call)) {
          _callApprovals[cacheKey] = ApprovalDecision.allow;
        }
        return ApprovalDecision.allow;
      }
      autoFallback = mode != PermissionMode.auto
          ? 'mode changed to ${mode.label}'
          : result.allow == false
          ? 'classifier recommends denial${autoDenialReason == null ? '' : ': $autoDenialReason'}'
          : 'classifier ${result.failure ?? 'unavailable'}';
      if (autoDiagnostics['model'] is String) {
        autoFallback = '$autoFallback (${autoDiagnostics['model']})';
      }
      terminal?.writeln('$autoFallback — asking you: $target');
    }
    final fallbackSentence = autoFallback == null
        ? null
        : RegExp(r'[.!?]$').hasMatch(autoFallback)
        ? autoFallback
        : '$autoFallback.';
    final decision =
        await approvals?.request(
          operation: operation,
          target: target,
          kind: kind,
          reason: autoFallback == null
              ? reason
              : 'Auto approval: $fallbackSentence $reason',
          details: {
            ...context,
            if (_call != null)
              'tool': {'name': _call!.name, 'input': _call!.input},
            'mode': mode.name,
            if (autoFallback != null) 'auto_approval_fallback': autoFallback,
            if (autoDenialReason != null)
              'auto_approval_denial_reason': autoDenialReason,
            if (autoDiagnostics.isNotEmpty)
              'auto_approval_classifier': autoDiagnostics,
          },
        ) ??
        ApprovalDecision.deny;
    if (invalid()) return ApprovalDecision.deny;
    if (permission &&
        call != null &&
        identical(call, _call) &&
        decision == ApprovalDecision.allow) {
      _callApprovals[cacheKey] = decision;
    }
    return decision;
  }

  @override
  void onInput(TurnContext context) {
    _turn = context;
  }

  @override
  void beforeToolCall(TurnContext context) {
    _callApprovals.clear();
    _call = context.call;
  }

  @override
  void afterToolResult(TurnContext context) {
    _call = null;
    _callApprovals.clear();
  }

  @override
  void onTurnEnd(TurnContext context) {
    _turn = null;
    _call = null;
    _callApprovals.clear();
  }

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    _writeState = null;
    _closedSignal.complete();
    _listeners.clear();
  }
}
