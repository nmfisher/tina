/// Approval precedents: normalized permission-request signatures, the
/// similarity ranking that retrieves them, and the deterministic fast-path
/// predicate.
///
/// Pure by construction: no I/O and no `dart:io` (listed in the repository
/// policy's `pureFiles`). Persistence lives in `precedent_store.dart`.
library;

import 'dart:convert';

/// What a resolved request became. A cancellation is not an outcome.
enum PrecedentOutcome { allow, deny }

/// Who decided. Weights are advisory: the ranker and the judge prompt treat
/// a human decision as stronger evidence than a classifier judgment.
enum PrecedentAuthority { humanAlways, humanOnce, classifier }

/// The directory world a request is classified against. Paths are reduced to
/// these classes before storage, so no raw path or argument is kept.
final class PrecedentScope {
  const PrecedentScope({
    required this.workspace,
    this.readDirectories = const [],
    this.writeDirectories = const [],
  });

  final String workspace;
  final List<String> readDirectories;
  final List<String> writeDirectories;

  static const workspaceClass = 'workspace';
  static const grantedClass = 'granted';
  static const outsideClass = 'outside';

  /// Classify [path] as workspace, granted (by a read/write directory) or
  /// outside. A relative path is resolved against the workspace.
  String classify(String path) {
    final normalized = _normalizePath(path);
    if (normalized.isEmpty) return outsideClass;
    final absolute = normalized.startsWith('/')
        ? normalized
        : '${_normalizePath(workspace)}/$normalized';
    if (_under(absolute, workspace)) return workspaceClass;
    for (final directory in [...readDirectories, ...writeDirectories]) {
      if (_under(absolute, directory)) return grantedClass;
    }
    return outsideClass;
  }
}

String _normalizePath(String value) {
  var path = value.trim().replaceAll(RegExp(r'/+'), '/');
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

bool _under(String path, String root) {
  final base = _normalizePath(root);
  if (base.isEmpty) return false;
  if (path == base) return true;
  final prefix = base.endsWith('/') ? base : '$base/';
  return path.startsWith(prefix);
}

String _basename(String path) {
  final normalized = _normalizePath(path);
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

/// Long, opaque values are never stored: the signature keeps a class, not the
/// text. This is the last line of defence for secrets passed as arguments.
bool _looksSecret(String value) {
  if (value.length > 48) return true;
  if (RegExp(r'^(sk|pk|ghp|gho|ghs|xox[abps]|AKIA|ASIA)[-_A-Za-z0-9]{12,}$')
      .hasMatch(value)) {
    return true;
  }
  final separator = value.indexOf('=');
  if (separator > 0 && separator < value.length - 1) {
    final name = value.substring(0, separator).toLowerCase();
    if (RegExp(r'(key|token|secret|password|passwd|credential|auth)')
        .hasMatch(name)) {
      return true;
    }
  }
  // A 32+ character high-entropy run with no separators is treated as opaque.
  final compact = value.replaceAll(RegExp(r'[-_./]'), '');
  return compact.length >= 32 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(compact);
}

/// Normalized `--flag=value` / `-n2` / `-n 2` forms. Flags carry the risk
/// signal, so their names are kept and their values become classes.
String _normalizeFlag(String flag) {
  final equals = flag.indexOf('=');
  if (equals > 0) {
    final name = flag.substring(0, equals);
    final value = flag.substring(equals + 1);
    return '$name=${_shapeValue(value)}';
  }
  // Attached short-flag values: -n2, -n20.
  final attached = RegExp(r'^(-[A-Za-z])(\d+)$').firstMatch(flag);
  if (attached != null) return '${attached.group(1)}#';
  return flag;
}

String _shapeValue(String value) {
  if (RegExp(r'^\d+$').hasMatch(value)) return '#';
  if (_looksSecret(value)) return 'secret';
  return 'value';
}

/// The reduced form of one operand: never text, only a class.
String _shapeOperand(String value, PrecedentScope scope) {
  if (RegExp(r'^\d+$').hasMatch(value) || RegExp(r'^\d+\.\d+$').hasMatch(value)) {
    return '#';
  }
  if (_looksSecret(value)) return 'secret';
  if (value.contains('/') ||
      value.startsWith('.') ||
      value.startsWith('~') ||
      RegExp(r'\.[A-Za-z0-9]{1,8}$').hasMatch(value)) {
    return 'path:${scope.classify(value)}';
  }
  return 'word';
}

/// One permission request, reduced to the fields that carry risk.
final class RequestSignature {
  const RequestSignature({
    required this.tool,
    required this.program,
    required this.subcommand,
    required this.flags,
    required this.operands,
    required this.pathClasses,
    required this.permissions,
  });

  final String tool;

  /// The executable (command requests) or the operation (file requests).
  final String program;
  final String subcommand;

  /// Normalized flag tokens, deduplicated and sorted.
  final List<String> flags;

  /// Operand classes, in source order.
  final List<String> operands;
  final Set<String> pathClasses;

  /// Required permissions, sorted.
  final List<String> permissions;

  /// Canonical identity: two requests match exactly when their keys match.
  String get key => jsonEncode([
        tool,
        program,
        subcommand,
        [...flags]..sort(),
        operands,
        permissions,
      ]);

  Map<String, Object?> toJson() => {
        'tool': tool,
        'program': program,
        'subcommand': subcommand,
        'flags': flags,
        'operands': operands,
        'path_classes': pathClasses.toList()..sort(),
        'permissions': permissions,
      };

  static RequestSignature? fromJson(Object? raw) {
    if (raw is! Map) return null;
    List<String> strings(Object? value) =>
        value is List ? [for (final item in value) if (item is String) item] : const [];
    final tool = raw['tool'], program = raw['program'];
    if (tool is! String || program is! String || tool.isEmpty) return null;
    final flags = strings(raw['flags']);
    final operands = strings(raw['operands']);
    final pathClasses = strings(raw['path_classes']).toSet();
    final permissions = strings(raw['permissions']);
    if (permissions.isEmpty || flags.length > 64 || operands.length > 64) {
      return null;
    }
    return RequestSignature(
      tool: tool,
      program: program,
      subcommand: raw['subcommand'] is String ? raw['subcommand'] as String : '',
      flags: List.unmodifiable(flags),
      operands: List.unmodifiable(operands),
      pathClasses: Set.unmodifiable(pathClasses),
      permissions: List.unmodifiable(permissions),
    );
  }

  /// Build a signature from the evidence map `ModePlugin.request` already
  /// assembles for the judge. Null when the request has no recognizable shape:
  /// an unclassifiable request must never match a precedent.
  static RequestSignature? of(
    Map<String, Object?> request, {
    required PrecedentScope scope,
  }) {
    final operation = request['operation'];
    final tool = (request['tool'] as Map?)?['name'];
    final name = tool is String && tool.isNotEmpty
        ? tool
        : operation is String && operation.isNotEmpty
            ? operation
            : null;
    if (name == null) return null;
    final required = <String>[
      for (final value in (request['required_permissions'] as List?) ?? const [])
        if (value is String) value,
    ]..sort();
    final executable = request['executable'];
    if (executable is String && executable.isNotEmpty) {
      final arguments = <String>[
        for (final value in (request['arguments'] as List?) ?? const [])
          if (value is String) value,
      ];
      final flags = <String>[];
      final operands = <String>[];
      final pathClasses = <String>{};
      var subcommand = '';
      for (var i = 0; i < arguments.length; i++) {
        final argument = arguments[i];
        if (argument.startsWith('-') && argument.length > 1) {
          flags.add(_normalizeFlag(argument));
          // A short flag followed by a bare number is that flag's value.
          if (RegExp(r'^-[A-Za-z]$').hasMatch(argument) &&
              i + 1 < arguments.length &&
              RegExp(r'^\d+$').hasMatch(arguments[i + 1])) {
            flags[flags.length - 1] = '$argument#';
            i++;
          }
          continue;
        }
        if (subcommand.isEmpty && operands.isEmpty && flags.isEmpty) {
          subcommand = _looksSecret(argument) ? 'secret' : argument;
          continue;
        }
        final shape = _shapeOperand(argument, scope);
        operands.add(shape);
        if (shape.startsWith('path:')) pathClasses.add(shape.substring(5));
      }
      return RequestSignature(
        tool: name,
        program: _basename(executable),
        subcommand: subcommand,
        flags: List.unmodifiable(flags),
        operands: List.unmodifiable(operands),
        pathClasses: Set.unmodifiable(pathClasses),
        permissions: List.unmodifiable(required),
      );
    }
    // File-style requests: the operation is the program and the target path
    // the only operand.
    final target = request['target'];
    final pathClass =
        target is String && target.isNotEmpty ? scope.classify(target) : PrecedentScope.outsideClass;
    return RequestSignature(
      tool: name,
      program: operation is String ? operation : name,
      subcommand: '',
      flags: const [],
      operands: List.unmodifiable(['path:$pathClass']),
      pathClasses: Set.unmodifiable({pathClass}),
      permissions: List.unmodifiable(required),
    );
  }
}

/// One recorded decision.
final class ApprovalPrecedent {
  const ApprovalPrecedent({
    required this.signature,
    required this.outcome,
    required this.authority,
    required this.count,
    required this.lastSeen,
    this.coverage = 'unknown',
    this.conflicted = false,
  });

  final RequestSignature signature;
  final PrecedentOutcome outcome;
  final PrecedentAuthority authority;

  /// How many times this exact signature reached this outcome.
  final int count;
  final DateTime lastSeen;

  /// The access-assessment coverage recorded with the decision.
  final String coverage;

  /// A signature that has been both allowed and denied: always ask.
  final bool conflicted;

  String get key => signature.key;

  ApprovalPrecedent copyWith({
    PrecedentOutcome? outcome,
    PrecedentAuthority? authority,
    int? count,
    DateTime? lastSeen,
    String? coverage,
    bool? conflicted,
  }) =>
      ApprovalPrecedent(
        signature: signature,
        outcome: outcome ?? this.outcome,
        authority: authority ?? this.authority,
        count: count ?? this.count,
        lastSeen: lastSeen ?? this.lastSeen,
        coverage: coverage ?? this.coverage,
        conflicted: conflicted ?? this.conflicted,
      );

  Map<String, Object?> toJson() => {
        'signature': signature.toJson(),
        'outcome': outcome.name,
        'authority': authority.name,
        'count': count,
        'last_seen': lastSeen.toUtc().toIso8601String(),
        'coverage': coverage,
        'conflicted': conflicted,
      };

  static ApprovalPrecedent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final signature = RequestSignature.fromJson(raw['signature']);
    final lastSeen = raw['last_seen'] is String
        ? DateTime.tryParse(raw['last_seen'] as String)
        : null;
    final count = raw['count'];
    if (signature == null ||
        lastSeen == null ||
        count is! int ||
        count < 1 ||
        count > 1000000) {
      return null;
    }
    final outcome = PrecedentOutcome.values
        .where((value) => value.name == raw['outcome'])
        .firstOrNull;
    final authority = PrecedentAuthority.values
        .where((value) => value.name == raw['authority'])
        .firstOrNull;
    if (outcome == null || authority == null) return null;
    final coverage = raw['coverage'];
    return ApprovalPrecedent(
      signature: signature,
      outcome: outcome,
      authority: authority,
      count: count,
      lastSeen: lastSeen,
      coverage: coverage is String &&
              const {'complete', 'partial', 'unknown'}.contains(coverage)
          ? coverage
          : 'unknown',
      conflicted: raw['conflicted'] == true,
    );
  }
}

/// Merge a fresh decision into the stored record for the same signature.
///
/// A denial is never erased by a later approval: the pair becomes
/// [conflicted], which always asks. Repeating the same outcome only
/// increments the count and refreshes the timestamp.
ApprovalPrecedent mergeDecision(
  ApprovalPrecedent? existing, {
  required RequestSignature signature,
  required PrecedentOutcome outcome,
  required PrecedentAuthority authority,
  required DateTime at,
  String coverage = 'unknown',
}) {
  if (existing == null || existing.outcome == outcome) {
    // A model decision is not another human approval, and cannot refresh or
    // erase the human evidence used by the deterministic shortcut.
    if (existing != null &&
        authority == PrecedentAuthority.classifier &&
        existing.authority != PrecedentAuthority.classifier) return existing;
    final sameAuthority = existing != null &&
        (existing.authority == PrecedentAuthority.classifier) ==
            (authority == PrecedentAuthority.classifier);
    return ApprovalPrecedent(
      signature: signature,
      outcome: outcome,
      authority: authority,
      count: (sameAuthority ? existing.count : 0) + 1,
      lastSeen: at,
      coverage: coverage,
      conflicted: existing?.conflicted ?? false,
    );
  }
  return ApprovalPrecedent(
    signature: signature,
    outcome: existing.outcome,
    authority: existing.authority,
    count: existing.count,
    lastSeen: existing.lastSeen.isAfter(at) ? existing.lastSeen : at,
    coverage: existing.coverage,
    conflicted: true,
  );
}

double _dice(List<String> a, List<String> b) {
  if (a.isEmpty && b.isEmpty) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  final counts = <String, int>{};
  for (final value in a) {
    counts[value] = (counts[value] ?? 0) + 1;
  }
  var shared = 0;
  for (final value in b) {
    final remaining = counts[value] ?? 0;
    if (remaining > 0) {
      shared++;
      counts[value] = remaining - 1;
    }
  }
  return 2 * shared / (a.length + b.length);
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final union = {...a, ...b};
  if (union.isEmpty) return 1;
  return a.intersection(b).length / union.length;
}

/// Field-weighted similarity in `[0, 1]`.
///
/// A different program scores zero, whatever else matches: that gate is what
/// stops `git log` from vouching for `git push`. Character-distance metrics are
/// deliberately avoided — they cannot tell a harmless operand swap from a
/// dangerous one, because the signal lives in which field changed.
double similarity(RequestSignature candidate, RequestSignature request) {
  if (candidate.program != request.program) return 0;
  // A different subcommand is a different operation with the same binary:
  // `git log` must never vouch for `git push`. Only gate when both name one.
  if (candidate.subcommand.isNotEmpty &&
      request.subcommand.isNotEmpty &&
      candidate.subcommand != request.subcommand) {
    return 0;
  }
  return 0.30 +
      0.20 * (candidate.subcommand == request.subcommand ? 1 : 0) +
      0.20 * _dice(candidate.flags, request.flags) +
      0.20 * _dice(candidate.operands, request.operands) +
      0.10 * _jaccard(candidate.pathClasses, request.pathClasses);
}

/// Whether [precedent] may inform a judgment about [request].
///
/// Permission monotonicity: a precedent informs only when its permission set
/// covers the request. Network and unconfined access are never inherited.
bool usableAsEvidence(
  ApprovalPrecedent precedent,
  RequestSignature request, {
  double minimumSimilarity = 0.55,
}) {
  if (precedent.conflicted) return false;
  if (!precedent.signature.permissions.toSet().containsAll(request.permissions)) {
    return false;
  }
  return similarity(precedent.signature, request) >= minimumSimilarity;
}

/// Rank precedents for the judge, closest first. Deduplicated by outcome and
/// signature so one noisy class cannot fill the whole evidence block.
List<({ApprovalPrecedent precedent, double score})> rankPrecedents(
  RequestSignature request,
  Iterable<ApprovalPrecedent> candidates, {
  int limit = 4,
  double minimumSimilarity = 0.55,
}) {
  final ranked = <({ApprovalPrecedent precedent, double score})>[];
  for (final precedent in candidates) {
    if (!usableAsEvidence(precedent, request,
        minimumSimilarity: minimumSimilarity)) {
      continue;
    }
    ranked.add((
      precedent: precedent,
      score: similarity(precedent.signature, request),
    ));
  }
  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    // A denial outranks an approval at the same similarity: the safe side wins
    // ties.
    if (a.precedent.outcome != b.precedent.outcome) {
      return a.precedent.outcome == PrecedentOutcome.deny ? -1 : 1;
    }
    return b.precedent.lastSeen.compareTo(a.precedent.lastSeen);
  });
  final seen = <String>{};
  final out = <({ApprovalPrecedent precedent, double score})>[];
  for (final entry in ranked) {
    final identity = '${entry.precedent.outcome.name}\u0000${entry.precedent.key}';
    if (!seen.add(identity)) continue;
    out.add(entry);
    if (out.length >= limit) break;
  }
  return out;
}

/// The deterministic fast path: a read-only request whose exact shape the
/// human has already approved at least [requiredApprovals] times runs without a
/// model judgment.
///
/// Every condition is mandatory. This is the only place a precedent authorizes
/// anything by itself, and it cannot grant network or unconfined access because
/// the permission set must be exactly `{execution}`.
bool allowsWithoutJudgment({
  required RequestSignature request,
  required Iterable<ApprovalPrecedent> precedents,
  required String coverage,
  required bool allAccessesRead,
  int requiredApprovals = 2,
  Duration maxAge = const Duration(days: 90),
  DateTime? now,
}) {
  if (request.permissions.length != 1 ||
      request.permissions.single != 'execution') {
    return false;
  }
  // Only a complete, all-read assessment is eligible: partial or unknown
  // access is exactly the case a precedent must not shortcut.
  if (coverage != 'complete' || !allAccessesRead) return false;
  final at = now ?? DateTime.now().toUtc();
  var approvals = 0;
  for (final precedent in precedents) {
    if (precedent.key != request.key) continue;
    if (precedent.conflicted) return false;
    if (precedent.outcome == PrecedentOutcome.deny) return false;
    if (precedent.authority == PrecedentAuthority.classifier) continue;
    if (at.difference(precedent.lastSeen).abs() > maxAge) continue;
    approvals += precedent.count;
  }
  return approvals >= requiredApprovals;
}

/// How much a learned precedent may do. `off` restores v0.9.68 behaviour.
enum PrecedentMode { off, evidence, full }

PrecedentMode parsePrecedentMode(String? value) =>
    PrecedentMode.values
        .where((mode) => mode.name == (value ?? '').trim().toLowerCase())
        .firstOrNull ??
    PrecedentMode.evidence;

/// The evidence block handed to the judge. Bounded so a long history cannot
/// crowd the request.
List<Map<String, Object?>> precedentEvidence(
  List<({ApprovalPrecedent precedent, double score})> ranked, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now().toUtc();
  return [
    for (final entry in ranked)
      {
        'similarity': double.parse(entry.score.toStringAsFixed(2)),
        'outcome': entry.precedent.outcome.name,
        'authority': entry.precedent.authority.name,
        'count': entry.precedent.count,
        'age_days': at.difference(entry.precedent.lastSeen).inDays.clamp(0, 9999),
        'coverage': entry.precedent.coverage,
        'request': entry.precedent.signature.toJson(),
      },
  ];
}
