/// The permission rules for tina_tools, as pure logic.
///
/// Every tool declares its own [ToolCapabilities] — where it reads and
/// writes, whether it starts a process and who chose the arguments, whether
/// it reaches the network. This library turns those declared facts into a
/// [ToolVerdict] under a [PermissionMode], with no terminal, no event loop,
/// and no dependency beyond tina_core: mounting it onto a loop is the host's
/// job, and until then nothing answers an `ask` here.
///
/// Ported from the old engine's `deriveToolDecision` + read-all gate
/// (`packages/tina_engine/lib/src/permissions/policy.dart`), minimised:
/// no central tool table, no session rules, no grants, no classifier, no UI.
/// The reasoning — independent capability axes, worst-case for the undeclared,
/// an ask answered elsewhere, read-only never widens — carried over; the app
/// wiring did not.
///
/// The one invariant the old engine states in prose and this package makes
/// structural: **fail closed**. `ToolCapabilities.undeclared` is the worst
/// case on every axis, so a tool that says nothing is denied in readOnly and
/// asked about in normal — never allowed. And a tool whose
/// `escapesTheSandbox` is true can at best produce an `ask`: the policy
/// itself has no route to a silent `allow` for it.
library;

import 'tool_capabilities.dart';

/// What the policy decides about one tool call.
///
/// Named the policy's own type (not the loop's decision type) so the policy
/// and the runtime cannot be confused: an [ToolVerdict.ask] is *not* an
/// answer — whoever calls this decides, which is what lets a UI put the
/// question later.
enum ToolVerdict {
  /// Run it.
  allow,

  /// Refuse it.
  deny,

  /// Someone else decides — in normal mode a human is asked; in readOnly
  /// mode `check` has already turned this into a deny.
  ask;

  /// A short plain reason for [reasonFor], so verdicts explain themselves
  /// without the policy knowing any UI.
  String get _defaultReason => switch (this) {
        ToolVerdict.allow => 'declared read-only, inside the sandbox',
        ToolVerdict.deny => 'not permitted in read-only mode',
        ToolVerdict.ask => 'needs approval',
      };
}

/// Why the verdict is what it is, in one plain sentence a UI can show. The
/// rule keeps this next to each decision so a prompt or a denial note never
/// has to re-derive it from the capabilities again.
String reasonFor(ToolVerdict verdict, ToolCapabilities caps) {
  if (caps.escapesTheSandbox) {
    return switch (verdict) {
      ToolVerdict.deny =>
        '$verdict: read-only mode cannot grant it — it escapes the sandbox',
      _ =>
        '$verdict: it escapes the sandbox (${caps.justification ?? 'no reviewed justification'})',
    };
  }
  return switch (verdict) {
    ToolVerdict.allow => verdict._defaultReason,
    ToolVerdict.deny =>
      '$verdict: ${caps.touchesTheMachine ? 'not in read-only mode — it needs execution' : 'read-only grants nothing, and it touches nothing to read'}',
    ToolVerdict.ask => switch ((
      caps.reads,
      caps.writes,
      caps.spawns,
      caps.network,
      caps.indirect,
    )) {
      (ReadScope.none, _, _, _, _) when !caps.touchesTheMachine =>
        '$verdict: it touches nothing itself, so starting it is your decision',
      (_, WriteScope.none, SpawnScope.modelArgv, _, _) =>
        '$verdict: it runs a program whose arguments the model chose',
      (_, WriteScope.none, _, NetworkScope.egress, _) =>
        '$verdict: it reaches the network',
      (_, WriteScope.none, _, _, IndirectWork.anyProfile) =>
        '$verdict: it can set other agents that write in motion',
      (_, WriteScope.none, _, _, _) when caps.reads == ReadScope.host =>
        '$verdict: it reads the host, not just the project',
      (_, WriteScope.project, _, _, _) ||
      (_, WriteScope.sidecar, _, _, _) =>
        '$verdict: it writes inside the project',
      _ => '$verdict: ${verdict._defaultReason}',
    },
  };
}

/// Session-wide permission mode, layered on top of the per-tool defaults.
///
/// Only two to start. The old engine had four — `ask`, `readAll`,
/// `allowEdits`, and `auto` (an LLM classifier deciding each call). Left out
/// here: `allowEdits` (needs its own widening step and tests) and `auto`
/// (needs the classifier and a provider, which is app wiring, not policy).
/// Both would be additions to `check`, not changes to it.
enum PermissionMode {
  /// The built-in defaults: read-only tools run, everything else asks.
  normal,

  /// Read-only run: nothing here widens to allow, and an ask is answered
  /// `deny` — nobody may be asked to approve a write in a read-only run.
  readOnly,
}

/// One capability set judged under one mode.
typedef ToolCall = ({ToolCapabilities capabilities, PermissionMode mode});

/// From declared capabilities and a mode to a verdict: the whole rule.
///
/// Order matters and is deliberate:
///
/// 1. **readOnly narrows before anything else.** The only tools that run are
///    the declared reads-inside-the-project; every other capability set —
///    including an undeclared one — denies. An ask is a question, and
///    read-only promised not to ask.
/// 2. **Never silently allow what escapes the sandbox.** An uncontained
///    process, egress, a host read or host write is at best an ask, even
///    with a `reviewed` justification on it. (The old engine allowed
///    reviewed tools; this port keeps them at ask so the policy alone can
///    never be the reason a sandbox-escaping call runs.)
/// 3. Then the per-axis defaults: `modelArgv` and egress ask, a tool that
///    touches nothing asks (starting other work is the user's decision),
///    indirect work that can write asks, host reads ask, project writes ask.
/// 4. Reads only → allow.
///
/// An ask is not answered here: [check] returns the verdict and stops, so a
/// host with a UI puts the question and a host without one refuses.

/// The rule: capabilities × mode → verdict.
ToolVerdict check(ToolCall call) => checkWithReason(call).verdict;

/// The rule plus its reason, so a caller never re-derives the "why".
({ToolVerdict verdict, String reason}) checkWithReason(ToolCall call) {
  final caps = call.capabilities;
  final verdict = switch (call.mode) {
    // Read-only: allow only what reads the project and does nothing else —
    // no write, no spawn, no egress, no indirect work, and no undeclared
    // gap. Everything else is denied without a prompt: read-only never asks.
    PermissionMode.readOnly =>
      (caps.reads == ReadScope.project &&
              caps.writes == WriteScope.none &&
              caps.spawns == SpawnScope.none &&
              caps.network == NetworkScope.none &&
              caps.indirect == IndirectWork.none)
          ? ToolVerdict.allow
          : ToolVerdict.deny,
    // Normal: the per-axis defaults. `undeclared` is the worst case on every
    // axis, so it lands in ask, never allow.
    PermissionMode.normal => _normalVerdict(caps),
  };
  return (verdict: verdict, reason: reasonFor(verdict, caps));
}

/// Normal-mode defaults, derived per axis (ported `deriveToolDecision`,
/// with the sandbox-escape guard taking precedence over the `reviewed`
/// shortcut).
ToolVerdict _normalVerdict(ToolCapabilities caps) {
  if (caps.escapesTheSandbox) return ToolVerdict.ask;
  if (caps.spawns == SpawnScope.modelArgv) return ToolVerdict.ask;
  if (caps.network == NetworkScope.egress) return ToolVerdict.ask;
  if (caps.reads == ReadScope.none && !caps.touchesTheMachine) {
    return ToolVerdict.ask;
  }
  if (caps.indirect == IndirectWork.anyProfile) return ToolVerdict.ask;
  if (caps.reads == ReadScope.host) return ToolVerdict.ask;
  if (caps.writes != WriteScope.none) return ToolVerdict.ask;
  return ToolVerdict.allow;
}
