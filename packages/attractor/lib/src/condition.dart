import 'context.dart';
import 'outcome.dart';

/// A parsed edge condition expression — an AND of clauses, each
/// `key = literal` or `key != literal` (or a bare truthy key). Keys resolve
/// against the just-completed [Outcome] and the run [Context]:
/// `outcome`, `preferred_label`, or any `context.*` (or direct) key.
class Condition {
  final List<_Clause> clauses;

  Condition(this.clauses);

  /// Parse `outcome=success && context.tests_passed=true`. An empty expression
  /// is always true (the "unconditional" edge).
  static Condition? tryParse(String expr) {
    final trimmed = expr.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('&&');
    final clauses = <_Clause>[];
    for (final raw in parts) {
      final c = _Clause.tryParse(raw.trim());
      if (c == null) return null; // malformed → condition won't match
      clauses.add(c);
    }
    return Condition(clauses);
  }

  /// Evaluate against the current outcome/context. Missing context keys
  /// compare as empty strings (so `=` never matches, `!=` always does).
  bool evaluate(Outcome outcome, Context context) {
    for (final c in clauses) {
      if (!c.evaluate(outcome, context)) return false;
    }
    return true;
  }
}

class _Clause {
  /// null key = bare truthy check.
  final String? key;
  final String literal;
  final bool negate;

  _Clause(this.key, this.literal, this.negate);

  static _Clause? tryParse(String clause) {
    if (clause.isEmpty) return null;
    final not = clause.indexOf('!=');
    if (not >= 0) {
      return _Clause(
        clause.substring(0, not).trim(),
        _unquote(clause.substring(not + 2).trim()),
        true,
      );
    }
    // `==` (the documented style) — parse as equality, not key `=` literal
    // `=x`. Checked after `!=` and before a single `=`.
    final eqeq = clause.indexOf('==');
    if (eqeq >= 0) {
      return _Clause(
        clause.substring(0, eqeq).trim(),
        _unquote(clause.substring(eqeq + 2).trim()),
        false,
      );
    }
    final eq = clause.indexOf('=');
    if (eq >= 0) {
      return _Clause(
        clause.substring(0, eq).trim(),
        _unquote(clause.substring(eq + 1).trim()),
        false,
      );
    }
    // Bare key: truthy check (non-empty, "true").
    return _Clause(clause.trim(), '', false);
  }

  bool evaluate(Outcome outcome, Context context) {
    if (key == null) {
      // Unreachable — bare clauses set key to the token.
      return false;
    }
    final lhs = _resolveKey(key!, outcome, context);
    final bool truthyCheck = literal.isEmpty && !negate;
    if (truthyCheck) {
      return lhs == 'true';
    }
    // `outcome=success` treats partial_success as good enough — a partially
    // completed stage shouldn't dead-end into a failure branch it didn't ask
    // for — on both sides of the comparison (`!= success` also excludes
    // partial_success). Strict matching is still available via
    // `outcome=partial_success` / `outcome=fail`.
    if (key == 'outcome' && lhs == 'partial_success' && literal == 'success') {
      return !negate;
    }
    return negate ? lhs != literal : lhs == literal;
  }
}

String _resolveKey(String key, Outcome outcome, Context context) {
  switch (key) {
    case 'outcome':
      return outcome.status.wire;
    case 'preferred_label':
      return outcome.preferredLabel ?? '';
    default:
      if (key.startsWith('context.')) {
        final unqualified = key.substring('context.'.length);
        return context.get(key) ?? context.get(unqualified) ?? '';
      }
      return context.get(key) ?? '';
  }
}

String _unquote(String s) {
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s
        .substring(1, s.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }
  return s;
}

/// Evaluate a raw expression against the current outcome/context. Convenience
/// for callers that don't cache a parsed [Condition].
bool evaluateCondition(String expr, Outcome outcome, Context context) {
  final c = Condition.tryParse(expr);
  if (c == null) return expr.trim().isEmpty;
  return c.evaluate(outcome, context);
}
