library;

import 'dart:async';
import 'dart:convert';
import 'package:classification/permissions.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'observation.dart';
import 'authorization.dart';
export 'authorization.dart';
export 'mode.dart';
export 'observation.dart';
export 'operations.dart';
export 'settings.dart';
export 'package:classification/permissions.dart';

/// Owns permission mode and approval routing. Tools enforce its decisions;
/// a console attachment renders it without introducing terminal dependencies.
abstract interface class ModePolicySource {
  ModePlugin get modePolicy;
}

class ModePlugin extends AgentPlugin implements ModeControl, ModePolicySource {
  ModePlugin({
    PermissionMode mode = PermissionMode.ask,
    this.terminal,
    this.approvals,
    this.classifier,
  }) : _mode = mode;
  @override
  String get id => 'tina/mode';
  @override
  ModePlugin get modePolicy => this;
  @override
  int get order => 9;
  @override
  PermissionMode get mode => _mode;
  PermissionMode _mode;
  late final ModeObservation observation = _ModeObservation(this);
  void Function(PluginStateEntry)? _writeState;
  @override
  void mountOn(AgentLoop loop) => mountPolicy(loop, ownerId: id);

  String _stateOwner = 'tina/mode';
  void mountPolicy(AgentLoop loop, {required String ownerId}) {
    _stateOwner = ownerId;
    // yolo is a launch-time override: it is never persisted, and restored
    // session state must not overwrite it.
    if (_mode == PermissionMode.yolo) {
      _writeState = loop.stateWriter(ownerId);
      return;
    }
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
  int _revision = 0;
  int get revision => _revision;
  Future<void> get whenChanged => _changed.future;
  void Function()? _stopParent;

  /// Children follow the parent's live permission ceiling.
  void inheritPolicy(ModePlugin parent) {
    _stopParent?.call();
    mode = parent.mode;
    _stopParent = parent.listen((value) => mode = value);
  }

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
    _revision++;
    _callApprovals.clear();
    _changed.complete();
    _changed = Completer<void>();
    for (final listener in _listeners.toList()) {
      if (_listeners.contains(listener)) listener(value);
    }
  }

  void Function() listen(void Function(PermissionMode) listener) {
    if (_closed) throw StateError('Mode policy is closed');
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  bool Function(String capability, String target)? hasAccessGrant;
  void Function(String capability, String target, ApprovalDecision decision)?
  saveAccessGrant;
  bool persistentAccessGrants = false;
  Terminal? terminal;
  ApprovalRequester? approvals;
  PermissionClassifier? classifier;

  /// Where resolved decisions are remembered, and the world their path classes
  /// are computed against. Null disables the feature entirely.
  PrecedentStore? precedentStore;
  PrecedentScope Function()? precedentScope;

  /// Reads the `permissions.precedents` setting for the current scope.
  PrecedentMode Function()? readPrecedentMode;
  TurnContext? _turn;
  ToolUse? _call;
  // One approval covers one invocation, including atomic temp/rename writes.
  // It never survives afterToolResult or a mode change.
  final Map<String, ApprovalDecision> _callApprovals = {};
  final Map<String, int> _approvalRequestCounts = {};

  /// Local counts only: no commands, paths, environment or model answers.
  Map<String, int> get approvalRequestCounts =>
      Map.unmodifiable(_approvalRequestCounts);
  bool _closed = false;

  /// The modes selectable through `/mode`. yolo is start-time only and is
  /// deliberately excluded so the command and its completion can't reach it.
  static final modeWords = List<String>.unmodifiable(
    PermissionMode.values
        .where((m) => m != PermissionMode.yolo)
        .map((m) => m.label),
  );
  static PermissionMode? parseMode(String word) {
    for (final mode in PermissionMode.values) {
      if (mode == PermissionMode.yolo) continue;
      if (mode.label == word.trim()) return mode;
    }
    return null;
  }

  static String wordFor(PermissionMode mode) => mode.label;

  void selectMode(
    PermissionMode value, {
    required PermissionMode expectedMode,
  }) {
    if (_closed) throw StateError('Mode policy is closed');
    if (mode != expectedMode) throw StateError('Permission mode changed');
    mode = value;
  }

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
        if (argument.trim().isEmpty && _approvalRequestCounts.isNotEmpty) {
          terminal?.writeln(
            'approval requests: ${_approvalRequestCounts.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
          );
        }
      },
    ),
  ];

  /// Precedent evidence for one request, or empty when the feature is off or
  /// the request has no recognizable shape. Wired into the classifier by the
  /// application assembly.
  List<Map<String, Object?>> precedentEvidenceFor(
    Map<String, Object?> request,
  ) {
    final mode = readPrecedentMode?.call() ?? PrecedentMode.evidence;
    if (mode == PrecedentMode.off) return const [];
    final store = precedentStore;
    final scope = precedentScope?.call();
    if (store == null || scope == null) return const [];
    final signature = RequestSignature.of(request, scope: scope);
    if (signature == null) return const [];
    try {
      return precedentEvidence(rankPrecedents(signature, store.read()));
    } catch (_) {
      return const []; // A damaged history never blocks a judgment.
    }
  }

  /// Record how a permission request was resolved. Cancellations and automatic
  /// denials with no human present never reach this method.
  void _rememberDecision(
    Map<String, Object?> request, {
    required ApprovalDecision decision,
    required bool human,
    String? coverage,
  }) {
    final mode = readPrecedentMode?.call() ?? PrecedentMode.evidence;
    if (mode == PrecedentMode.off) return;
    final store = precedentStore;
    final scope = precedentScope?.call();
    if (store == null || scope == null) return;
    final signature = RequestSignature.of(request, scope: scope);
    if (signature == null) return;
    final approved = switch (decision) {
      ApprovalDecision.allow ||
      ApprovalDecision.allowAlways ||
      ApprovalDecision.allowWorkspace ||
      ApprovalDecision.allowGlobal ||
      ApprovalDecision.allowReadsInDirectory ||
      ApprovalDecision.allowAlwaysAndReadsInDirectory ||
      ApprovalDecision.allowWritesInDirectory ||
      ApprovalDecision.allowAlwaysAndWritesInDirectory ||
      ApprovalDecision.allowReadsAlways => true,
      ApprovalDecision.deny => false,
    };
    final authority = !human
        ? PrecedentAuthority.classifier
        : switch (decision) {
            ApprovalDecision.allowAlways ||
            ApprovalDecision.allowWorkspace ||
            ApprovalDecision.allowGlobal ||
            ApprovalDecision.allowReadsAlways => PrecedentAuthority.humanAlways,
            _ => PrecedentAuthority.humanOnce,
          };
    try {
      store.record(
        signature: signature,
        outcome: approved ? PrecedentOutcome.allow : PrecedentOutcome.deny,
        authority: authority,
        coverage: coverage ?? 'unknown',
      );
    } catch (_) {
      // Remembering is best effort; the decision itself already stands.
    }
  }

  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    Map<String, Object?> context = const {},
    ApprovalKind kind = ApprovalKind.permission,
    bool humanOnly = false,
    AuthorizationRequest? authorization,
    void Function(String pattern)? onCommandPattern,
    void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants,
    Map<String, Object?> Function(PermissionJudgment judgment)?
    prepareAccessReview,
  }) async {
    final turn = _turn;
    bool invalid() =>
        _closed || turn?.cancelled == true || !identical(turn, _turn);
    if (invalid()) return ApprovalDecision.deny;
    final policyRevision = revision;
    final policyChanged = whenChanged;
    Future<ApprovalDecision> reconsider() => request(
      operation: operation,
      target: target,
      reason: reason,
      context: context,
      kind: kind,
      humanOnly: humanOnly,
      authorization: authorization,
      onCommandPattern: onCommandPattern,
      onDirectoryGrants: onDirectoryGrants,
      prepareAccessReview: prepareAccessReview,
    );
    final external =
        context['permission_scope'] == 'mcp' ||
        (context['required_permissions'] is Iterable &&
            (context['required_permissions'] as Iterable).any(
              (p) => {'network', 'unconfined', 'directoryAccess'}.contains(p),
            ));
    final identity = context['authorization_identity'] is String
        ? context['authorization_identity'] as String
        : target;
    final mcp = context['permission_scope'] == 'mcp';
    final mcpRead =
        context['mcp_method'] == 'resources/read' ||
        context['mcp_method'] == 'prompts/get';
    final capability = mcpRead
        ? AccessCapability.read
        : external
        ? AccessCapability.external
        : operation == 'run command'
        ? AccessCapability.execute
        : AccessCapability.write;
    final canonical =
        authorization ??
        AuthorizationRequest(
          requirements: [
            AccessRequirement(
              capability,
              identity,
              workspace: !external,
              granted:
                  mcp &&
                  hasAccessGrant?.call(capability.name, identity) == true,
            ),
          ],
        );
    final resolution = resolveAuthorization(canonical, mode, kind: kind);
    if (resolution.route == AuthorizationRoute.deny) {
      terminal?.writeln(resolution.reason);
      return ApprovalDecision.deny;
    }
    if (resolution.route == AuthorizationRoute.allow)
      return ApprovalDecision.allow;
    final requireHuman =
        humanOnly || resolution.route == AuthorizationRoute.human;
    final call = _call;
    final requiredPermissions = context['required_permissions'];
    final cacheKey = jsonEncode([
      operation, requireHuman,
      // File atomic staging shares its logical file operation; commands/MCP bind identity.
      operation == 'write' || operation == 'read' ? null : target,
      authorization?.toJson(),
      requiredPermissions is Iterable ? requiredPermissions.toList() : const [],
      // File tools own their logical operation (including atomic temporary
      // paths). Commands additionally bind the complete execution identity.
      operation == 'run command' ? target : null,
      context['approval_identity'], context['invocation_directory_access'],
    ]);
    final permission = kind == ApprovalKind.permission;
    if (permission && call != null && _callApprovals.containsKey(cacheKey)) {
      return _callApprovals[cacheKey]!;
    }
    String? autoFallback;
    String? autoDenialReason;
    Map<String, Object?> autoDiagnostics = const {};
    // The evidence map is assembled once: the judge sees it, and precedents
    // are keyed by exactly the same fields.
    Map<String, Object?> requestEvidence() => {
      'operation': operation,
      'target': target,
      'reason': reason,
      ...context,
      ...canonical.toJson(mode: mode),
      'authorization_reason': resolution.reason,
      // Owned by the active turn, not the tool's justification or
      // caller-supplied context. Null means no current user request.
      'user_request': turn?.input.text,
      if (_call != null) 'tool': {'name': _call!.name, 'input': _call!.input},
      // The conversation tail before this request: what a user
      // correction refers to. Without it, "that path is not
      // correct" denies the corrected retry because the judge
      // cannot see the failed call it answered.
      ...?_recentContext(turn),
    };
    var judgment = const PermissionJudgment(null, 'not classified');
    if (mode == PermissionMode.auto && permission && !requireHuman) {
      final evidence = requestEvidence();
      // Deterministic fast path: an exact read-only shape the user has already
      // approved twice runs without a model round trip.
      if (_precedentAllows(evidence)) {
        terminal?.writeln('$operation allowed by precedent: $target');
        if (call != null && identical(call, _call)) {
          _callApprovals[cacheKey] = ApprovalDecision.allow;
        }
        return ApprovalDecision.allow;
      }
      final judge = classifier;
      final result = judge == null
          ? const PermissionJudgment(null, 'not configured')
          : await judge.classify(
              evidence,
              whenCancelled: Future.any([
                if (turn != null) turn.whenCancelled,
                _changed.future,
                _closedSignal.future,
              ]),
            );
      if (invalid()) return ApprovalDecision.deny;
      if (revision != policyRevision) return reconsider();
      judgment = result;
      autoDiagnostics = result.diagnostics;
      if (result.allow == false) autoDenialReason = result.reason;
      if (mode == PermissionMode.auto && result.allow == true) {
        terminal?.writeln('$operation allowed by classifier: $target');
        // Classifier approvals apply once, never become human session grants.
        if (call != null && identical(call, _call)) {
          _callApprovals[cacheKey] = ApprovalDecision.allow;
        }
        _rememberDecision(
          evidence,
          decision: ApprovalDecision.allow,
          human: false,
          coverage: judgment.assessment.coverage.name,
        );
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
    final reasonCodes = <String>{
      if (context['approval_reason_codes'] case final List codes)
        for (final code in codes)
          if (code is String &&
              const {
                'missing_directory_access',
                'host_execution',
                'grant_mismatch',
              }.contains(code))
            code,
      if (autoFallback != null)
        judgment.allow == false ? 'classifier_denial' : 'classifier_failure',
    };
    if (reasonCodes.isEmpty) reasonCodes.add('permission_mode');
    if (approvals != null) {
      for (final code in reasonCodes) {
        _approvalRequestCounts.update(
          code,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final decision = await Future.any<ApprovalDecision>([
      approvals?.request(
            operation: operation,
            target: target,
            kind: kind,
            reason: autoFallback == null
                ? reason
                : 'Auto approval: $fallbackSentence $reason',
            whenCancelled: Future.any([
              policyChanged,
              _closedSignal.future,
              if (turn != null) turn.whenCancelled,
            ]),
            details: {
              ...context,
              ...canonical.toJson(mode: mode),
              if (mcp && persistentAccessGrants)
                'persistent_command_approval': true,
              'authorization_reason': resolution.reason,
              'approval_reason_codes': reasonCodes.toList(),
              if (prepareAccessReview != null)
                ...prepareAccessReview(judgment)
              else if (judgment.assessment.accesses.isNotEmpty ||
                  judgment.assessment.unresolved.isNotEmpty ||
                  judgment.assessment.coverage !=
                      PermissionAccessCoverage.unknown) ...{
                'accesses': [
                  for (final access in judgment.assessment.accesses)
                    {...access.toJson(), 'source': 'inferred'},
                ],
                'access_coverage': judgment.assessment.coverage.name,
                'access_coverage_source': 'inferred',
                'unresolved_accesses': judgment.assessment.unresolved,
              },
              if (_call != null)
                'tool': {'name': _call!.name, 'input': _call!.input},
              'mode': mode.name,
              if (autoFallback != null) 'auto_approval_fallback': autoFallback,
              if (autoDenialReason != null)
                'auto_approval_denial_reason': autoDenialReason,
              if (autoDiagnostics.isNotEmpty)
                'auto_approval_classifier': autoDiagnostics,
            },
            onCommandPattern: onCommandPattern == null
                ? null
                : (pattern) {
                    if (!invalid() && revision == policyRevision)
                      onCommandPattern(pattern);
                  },
            onDirectoryGrants: onDirectoryGrants == null
                ? null
                : (grants) {
                    if (!invalid() && revision == policyRevision)
                      onDirectoryGrants(grants);
                  },
          ) ??
          Future.value(ApprovalDecision.deny),
      policyChanged.then((_) => ApprovalDecision.deny),
      _closedSignal.future.then((_) => ApprovalDecision.deny),
      if (turn != null) turn.whenCancelled.then((_) => ApprovalDecision.deny),
    ]);
    if (invalid()) return ApprovalDecision.deny;
    if (revision != policyRevision) return reconsider();
    if (permission &&
        call != null &&
        identical(call, _call) &&
        decision == ApprovalDecision.allow) {
      _callApprovals[cacheKey] = decision;
    }
    if (mcp &&
        {
          ApprovalDecision.allowAlways,
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal,
        }.contains(decision)) {
      saveAccessGrant?.call(capability.name, identity, decision);
    }
    // Only a human answer is recorded here; the classifier's own ALLOW already
    // returned above, and an unattended automatic denial is not a decision the
    // user made.
    if (permission && approvals != null) {
      _rememberDecision(
        requestEvidence(),
        decision: decision,
        human: true,
        coverage: judgment.assessment.coverage.name,
      );
    }
    return decision;
  }

  /// Whether this exact read-only shape has been approved often enough to run
  /// quietly. Every condition is checked here; the pure predicate in the
  /// classification package holds the arithmetic.
  bool _precedentAllows(Map<String, Object?> evidence) {
    if ((readPrecedentMode?.call() ?? PrecedentMode.evidence) !=
        PrecedentMode.full) {
      return false;
    }
    final store = precedentStore;
    final scope = precedentScope?.call();
    if (store == null || scope == null) return false;
    final signature = RequestSignature.of(evidence, scope: scope);
    if (signature == null) return false;
    final accesses = evidence['accesses'];
    final allRead =
        evidence['access_coverage_source'] == 'verified' &&
        accesses is List &&
        accesses.isNotEmpty &&
        accesses.every(
          (access) =>
              access is Map &&
              access['operation'] == 'read' &&
              access['source'] == 'verified',
        );
    final coverage = evidence['access_coverage'];
    try {
      return allowsWithoutJudgment(
        request: signature,
        precedents: store.read(),
        coverage: coverage is String ? coverage : 'unknown',
        allAccessesRead: allRead,
      );
    } catch (_) {
      return false;
    }
  }

  /// The conversation tail for the judge, or null when there is nothing
  /// recent to resolve. Keeps the last few user texts and tool calls so a
  /// correction ("that path is not correct") can be matched to the call it
  /// answers — while excluding the tool result payloads and file dumps the
  /// conversation carries, which the judge does not need and which bloat
  /// the request with unneeded file contents.
  Map<String, Object?>? _recentContext(TurnContext? turn) {
    if (turn == null) return null;
    final users = <Map<String, Object?>>[];
    final tools = <Map<String, Object?>>[];
    String clip(String text, int limit) =>
        text.length <= limit ? text : '${text.substring(0, limit)}…';
    // Outcomes by toolUseId, so each recent call carries what actually
    // happened: the judge sees "the write to the wrong volume FAILED",
    // not just that it happened.
    final outcomes = <String, Map<String, Object?>>{};
    for (final message in turn.messages) {
      for (final block in message.content) {
        if (block is! ToolResultBlock) continue;
        outcomes[block.toolUseId] = block.isError
            ? {'error': clip(block.content.trim(), 300)}
            : const {'ok': true};
      }
    }
    for (final message in turn.messages.reversed) {
      if (users.length >= 3 && tools.length >= 3) break;
      for (final block in message.content.reversed) {
        if (users.length >= 3 && tools.length >= 3) break;
        if (block is TextBlock && message.role == Role.user) {
          final text = clip(block.text.trim(), 500);
          if (text.isNotEmpty) {
            users.add({'text': text});
          }
        } else if (block is ToolUseBlock) {
          tools.add({
            'name': block.name,
            'input': clip(block.input.toString(), 300),
            ...?outcomes[block.id],
          });
        }
      }
    }
    if (users.isEmpty && tools.isEmpty) return null;
    return {
      if (users.isNotEmpty)
        'recent_context': {'user_messages': users.reversed.toList()},
      if (tools.isNotEmpty) 'recent_tool_calls': tools.reversed.toList(),
    };
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
    _revision++;
    _stopParent?.call();
    _writeState = null;
    _closedSignal.complete();
    _listeners.clear();
  }
}

/// Runtime declaration for /mode. The tools plugin retains policy ownership.
final class ModeControlsPlugin extends AgentPlugin implements ModePolicySource {
  ModeControlsPlugin(this.modePolicy);
  @override
  final ModePlugin modePolicy;
  @override
  String get id => 'tina/mode';
  @override
  int get order => modePolicy.order;
  @override
  List<Command> get commands => modePolicy.commands;
  ModeObservation get observation => modePolicy.observation;
}

final class _ModeObservation implements ModeObservation {
  _ModeObservation(this._policy);
  final ModePlugin _policy;
  @override
  PermissionMode get mode => _policy.mode;
  @override
  void Function() listen(void Function(PermissionMode) listener) {
    late final void Function() release;
    release = _policy.listen((value) {
      try {
        listener(value);
      } catch (_) {
        release();
      }
    });
    return release;
  }
}
