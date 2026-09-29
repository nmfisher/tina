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
  final _listeners = <void Function(PermissionMode)>[];
  Completer<void> _changed = Completer<void>();
  final _closedSignal = Completer<void>();
  @override
  set mode(PermissionMode value) {
    if (_mode == value) return;
    _mode = value;
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
  }) async {
    final turn = _turn;
    bool invalid() =>
        _closed ||
        turn?.cancelled == true ||
        !identical(turn, _turn) ||
        mode == PermissionMode.readOnly;
    if (invalid()) return ApprovalDecision.deny;
    if (mode == PermissionMode.auto) {
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
      if (mode == PermissionMode.auto && result.allow == true) {
        terminal?.writeln('$operation allowed by classifier: $target');
        // Classifier approvals apply once, never become human session grants.
        return ApprovalDecision.allow;
      }
      terminal?.writeln(
        result.allow == false
            ? 'classifier recommends denial — asking you: $target'
            : 'classifier ${result.failure ?? 'mode changed'} — asking you: $target',
      );
    }
    final decision =
        await approvals?.request(
          operation: operation,
          target: target,
          reason: reason,
        ) ??
        ApprovalDecision.deny;
    return invalid() ? ApprovalDecision.deny : decision;
  }

  @override
  void onInput(TurnContext context) {
    _turn = context;
  }

  @override
  void beforeToolCall(TurnContext context) {
    _call = context.call;
  }

  @override
  void afterToolResult(TurnContext context) {
    _call = null;
  }

  @override
  void onTurnEnd(TurnContext context) {
    _turn = null;
    _call = null;
  }

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    _listeners.clear();
  }
}
