/// The typed view over the one scopes store.
///
/// Every remembered permission in [CommandApprovalStore] — command patterns,
/// read/write directory settings, trusted readers, file access and MCP
/// (server, tool) rules — becomes a [ScopeRule] with the same shape:
/// what is allowed, where it applies, at which scope, decided by whom.
/// The remembered-permissions screen and the auto-mode classifier's
/// recorded decisions both read through this view, so `auto` entries are
/// as visible and removable as human ones.
library;

import 'command_approval_store.dart';

/// What a remembered entry allows.
enum ScopeRuleKind {
  /// A remembered command pattern or exact command grant.
  command,

  /// A read/write directory setting or an access grant (file or MCP rule).
  access,

  /// A trusted reader executable (pinned digest).
  reader,

  /// A plugin permission setting persisted with the approvals.
  setting,
}

/// One remembered rule. [display] carries the human-readable line the
/// management screen shows; [decidedBy] is `user` or `auto`.
final class ScopeRule {
  ScopeRule._({
    required this.id,
    required this.kind,
    required this.scope,
    required this.workspace,
    required this.decidedBy,
    required this.display,
    required this.payload,
  });

  /// Stable identity for revocation.
  final String id;

  /// What kind of allowance this is.
  final ScopeRuleKind kind;

  /// session, workspace or global.
  final CommandApprovalScope scope;

  /// Null at global scope; the workspace path the rule applies to.
  final String? workspace;

  /// `user` or `auto`. Absent fields read as `user` — stores written before
  /// automatic decisions existed hold only human entries.
  final String decidedBy;

  /// The management-screen line.
  final String display;

  /// The entry itself, for callers that need kind-specific fields.
  final Map<String, Object?> payload;

  /// Build a rule from a store entry, or null when the entry carries no
  /// recognizable shape.
  static ScopeRule? of(Map<String, Object?> entry) {
    final id = entry['id'];
    final scopeName = entry['scope'];
    if (id is! String || scopeName is! String) return null;
    final kind = switch (entry['kind']) {
      'access' => ScopeRuleKind.access,
      'reader' => ScopeRuleKind.reader,
      'setting' => ScopeRuleKind.setting,
      null => ScopeRuleKind.command,
      _ => null,
    };
    if (kind == null) return null;
    return ScopeRule._(
      id: id,
      kind: kind,
      scope: CommandApprovalScope.values.asNameMap()[scopeName] ??
          CommandApprovalScope.session,
      workspace: entry['workspace'] as String?,
      decidedBy: (entry['decided_by'] as String?) ?? 'user',
      display: [
        if (entry['pattern'] case final String pattern)
          'regex: $pattern'
        else if (entry['command'] case final String command)
          command
        else
          '${entry['capability'] ?? entry['setting'] ?? id}',
        '(${entry['directory'] ?? entry['workspace'] ?? 'any directory'})',
      ].join(' '),
      payload: entry,
    );
  }
}

/// The fold: one list of rules over every remembered permission.
List<ScopeRule> scopeRules(CommandApprovalStore store) => [
      for (final entry in store.entries)
        if (ScopeRule.of(entry) case final rule?) rule,
    ].toList(growable: false);
