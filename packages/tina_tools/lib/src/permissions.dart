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
/// The reasoning — independent capability axes, worst case for the
/// undeclared, an ask answered elsewhere, read-only never widens — carried
/// over; the app wiring did not.
///
/// The one invariant the old engine states in prose this package makes
/// structural: **fail closed**. [ToolCapabilities.undeclared] is the worst
/// case on every axis, so a tool that says nothing is denied in readOnly and
/// asked about in normal — never allowed. And a tool whose
/// [ToolCapabilities.escapesTheSandbox] is true can at best produce an ask:
/// there is no route from this policy to a silent allow for one, whatever
/// its `reviewed` justification says.
library;

import 'tool_capabilities.dart';

/// What the policy decides about one tool call.
///
/// Named the policy's own type (not the runtime's decision type) so the
/// policy and the loop cannot be confused: an [ToolVerdict.ask] is *not* an
/// answer — whoever calls this decides, which is what lets a UI put the
/// question later.
enum ToolVerdict {
  /// Run it.
  allow,

  /// Refuse it.
  deny,

  /// Someone else decides — in normal mode a human is asked; in readOnly
  /// mode `check` has already turned this into a deny.
  ask,
}

/// Why the verdict is what it is, in one plain phrase a UI can show. Kept
/// next to the rule so a prompt or a denial note never has to re-derive the
/// "why" from the capabilities again.
String reasonFor(ToolVerdict verdict, ToolCapabilities caps) {
  if (caps.escapesTheSandbox) {
    final escape = switch ((
      caps.spawns == SpawnScope.modelArgv,
      caps.network == NetworkScope.egress,
      caps.writes == WriteScope.host,
      caps.reads == ReadScope.host,
    )) {
      (true, _, _, _) => 'it runs a program whose arguments the model chose',
      (_, true, _, _) => 'it reaches the network',
      (_, _, true, _) => 'it writes anywhere on the host',
      (_, _, _, true) => 'it reads the host, not just the project',
      _ => 'it escapes the sandbox',
    };
    final note =
        caps.justification == null ? '' : ' (reviewed: ${caps.justification})';
    return switch (verdict) {
      ToolVerdict.deny =>
        '$verdict: read-only mode cannot grant it — $escape$note',
      _ => '$verdict: $escape — this escapes the sandbox$note',
    };
  }
  return switch (verdict) {
    ToolVerdict.allow =>
      '$verdict: declared read-only and contained — '
      'nothing model-steered, nothing written',
    ToolVerdict.deny => switch (caps.indirect) {
        IndirectWork.anyProfile =>
          '$verdict: not in read-only mode — the agents it starts may write',
        _ =>
          caps.touchesTheMachine
              ? '$verdict: not in read-only mode — it needs execution'
              : '$verdict: read-only grants nothing, and it touches nothing to read',
      },
    ToolVerdict.ask => switch (caps.indirect) {
        IndirectWork.anyProfile =>
          '$verdict: it can set other agents that write in motion',
        _ when !caps.touchesTheMachine =>
          caps.indirect == IndirectWork.none
              ? '$verdict: it touches nothing itself, so starting it is your decision'
              : '$verdict: it only starts read-only agents, but starting '
                  'other work is your decision',
        _ when caps.writes != WriteScope.none =>
          '$verdict: it writes inside the project',
        _ => '$verdict: needs approval',
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
  /// The built-in defaults: contained reads run, everything else asks.
  normal,

  /// Read-only run: nothing widens to allow, and an ask is answered deny —
  /// nobody may be asked to approve a write in a read-only run.
  readOnly,
}

/// One capability set judged under one mode.
typedef ToolCall = ({ToolCapabilities capabilities, PermissionMode mode});

/// From declared capabilities and a mode to a verdict: the whole rule.
///
/// Order matters and is deliberate:
///
/// 1. **readOnly narrows before anything else.** The only tools that run are
///    the contained ones: reads inside the project (or nothing at all), no
///    writes, fixed — never model-chosen — argv if it spawns, other agents
///    only ever under the read-only profile. Everything else denies without
///    a prompt: an ask is a question, and read-only promised not to ask.
/// 2. **Never silently allow what escapes the sandbox.** A model-steered
///    argv, egress, a host read or a host write is at best an ask, even with
///    a `reviewed` justification on it. (The old engine allowed reviewed
///    tools; this port keeps them at ask so the policy alone can never be
///    the reason a sandbox-escaping call runs.)
/// 3. Then the per-axis asks: a tool that touches nothing asks — starting
///    other work is the user's decision; indirect work that can write asks;
///    a write inside the project asks.
/// 4. Whatever is left is a contained read (perhaps one that runs a fixed
///    program with fixed arguments) → allow.
///
/// An ask is not answered here: [check] returns the verdict and stops, so a
/// host with a UI puts the question and a host without one refuses.

/// The rule: capabilities × mode → verdict.
ToolVerdict check(ToolCall call) => checkWithReason(call).verdict;

/// The rule plus its reason, so a caller never re-derives the "why".
({ToolVerdict verdict, String reason}) checkWithReason(ToolCall call) {
  final caps = call.capabilities;
  final verdict = switch (call.mode) {
    // Read-only: allow only what stays inside a read-only run — contained
    // reads, no writes, no escape hatch, no agents that may write (and no
    // tool that touches nothing: read-only grants nothing either). Everything
    // else denies without a prompt.
    PermissionMode.readOnly =>
      _readOnlyRunAllows(caps) ? ToolVerdict.allow : ToolVerdict.deny,
    // Normal: the per-axis defaults. `undeclared` is the worst case on every
    // axis, so it lands in ask, never allow.
    PermissionMode.normal => _normalVerdict(caps),
  };
  return (verdict: verdict, reason: reasonFor(verdict, caps));
}

/// A read-only run permits exactly the tools that cannot leave one: machine
/// work that is fully contained, with nothing written, nothing model-steered,
/// no egress, and no agent that may write. A tool that touches nothing does
/// not qualify — read-only grants nothing, and it would not be asked either.
bool _readOnlyRunAllows(ToolCapabilities caps) =>
    caps.touchesTheMachine &&
    !caps.escapesTheSandbox &&
    caps.writes == WriteScope.none &&
    caps.indirect != IndirectWork.anyProfile;

/// Normal-mode defaults per axis (ported `deriveToolDecision`, with the
/// sandbox-escape guard taking precedence over the old `reviewed` shortcut).
ToolVerdict _normalVerdict(ToolCapabilities caps) {
  if (caps.escapesTheSandbox) return ToolVerdict.ask;
  if (caps.reads == ReadScope.none && !caps.touchesTheMachine) {
    return ToolVerdict.ask;
  }
  if (caps.indirect == IndirectWork.anyProfile) return ToolVerdict.ask;
  if (caps.writes != WriteScope.none) return ToolVerdict.ask;
  return ToolVerdict.allow;
}
