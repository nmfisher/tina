# Proposal: agent namespace — Plan 9-style agent integration

Status: proposal; not implemented.
Tickets: —
Related: `wasm_plugin_support.md` (tin-w4sm, Phase 5 capability broker),
`plugin_runtime.md` / PR #49 (PluginRuntime), region agents
(`packages/tina_app/lib/src/regions/`).

## 1. Summary

Give every conversation-spawned agent a **filesystem face**: a read/write
tree mounted under `/agent/<id>/…` inside a tina-private namespace, addressed
by path, with Plan 9 file semantics — read to inspect, write to command,
append to observe. Agent-to-agent communication becomes file I/O: one agent
writes a task to `/agent/<id>/task`, watches `/agent/<id>/status`, and reads
`/agent/<id>/result`. The same tree exposes region summaries, session
history, and (later) brokered host capabilities for WASM plugins.

The filesystem is a **protocol surface, not the implementation**. Spawning
still goes through `SubAgentScheduler`, enforcement still goes through
`ToolExecutor`/`PermissionPolicy`, persistence still goes through the
session store. No real 9P server, socket, or kernel is introduced; the
"mount" is an in-process virtual filesystem with 9P-style walk/read/write
verbs.

## 2. Problem

Agent cooperation today is call-shaped and tool-shaped:

- Delegation is a set of bespoke tools (`delegate`, `dispatch`, `continue`,
  `collect` on `SubAgentScheduler`), each with its own schema, result
  envelope, and error contract. Adding a new interaction shape means adding
  a new tool and teaching every surface about it.
- Region agents are queried through their own tools
  (`listRegions`/`queryRegion`/`broadcastRegion`); live conversations are
  invisible to other agents except through those five shapes.
- There is no uniform way for an agent to *observe* another agent (status,
  events, history) without owning it, and no way to address "the agent that
  owns X" other than remembering job ids.
- WASM plugins (tin-w4sm) will eventually need brokered host capabilities
  (Phase 5). Without a namespace, that broker needs its own bespoke
  protocol.

Plan 9's answer to this class of problem is: make resources files, make
per-process namespaces the security boundary, and let composition happen by
binding. Applied here, one addressing scheme covers spawn, supervise,
inspect, and communicate, and every access rides the existing permission
machinery instead of a parallel one.

## 3. Goals and non-goals

Goals:

- One address scheme for agents, regions, and (later) brokered resources.
- Agent-to-agent communication by file reads/writes with bounded, auditable
  semantics.
- Every file operation is a normal tool call: mandatory gates, phase guards,
  live policy check, approval flow, cancellation — nothing bypasses
  `ToolExecutor`.
- Per-conversation namespaces as the isolation boundary: a spawned agent's
  namespace is constructed, not discovered.

Non-goals (explicitly out of scope, in every phase):

- No network-listening 9P server, no external mount, no rio/acme/tmux
  integration. Nothing outside the tina process can walk this tree.
- No new execution engine: the filesystem does not schedule agents; it
  addresses the scheduler that exists.
- No replacement of `AgentEventBus`, provider streams, or the TUI render
  path. The tree mirrors state; it does not carry the hot path.
- No unbounded history/config files in the namespace; everything is size-
  and rate-bounded (specific numbers are committed per phase gate, not
  invented here).

## 4. Address space and file semantics

Rooted per conversation (the "per-process namespace"):

```
/agent/<id>/ctl          write-only command file: spawn|continue|cancel|collect
/agent/<id>/status       read-only  : idle|running|awaiting-approval|done|error
/agent/<id>/task         write-once task text (create = spawn a job)
/agent/<id>/result       read-once final text; emptied after read (like 9P pipe semantics)
/agent/<id>/events       append-only event log (bounded ring, JSON lines)
/agent/<id>/history      session transcript excerpt (bounded, read-only)
/agent/<id>/profile      read-only: tool profile ceiling, provider/model, depth
/region/<dir>/summary    read-only region summary (backs the region tools)
/region/<dir>/query      write task + read reply (backs queryRegion)
```

Rules (the whole contract, no special cases):

- **Read = snapshot.** A read of `status`/`result`/`history` returns a
  consistent snapshot; it never blocks on agent progress. `events` supports
  offset-capped reads (`?since=<seq>`); there is no blocking watch in early
  phases — pollers are bounded.
- **Write = command.** Writes to `ctl`/`task` are request/response: the
  write returns after the scheduler *accepts* (or an error), not after the
  work completes. Work completion shows up in `status`/`result`.
- **Create = spawn.** Creating `task` on a not-yet-running agent id is how a
  child is spawned; ids under `/agent` are host-assigned (session/agent ids)
  and cannot be forged by content.
- **Names are capabilities.** Visibility of a path is the permission to
  touch it: a child's namespace contains its own tree, the parent's
  `status`/`events` (observation only), and explicitly shared subtrees.
  There is no "list all agents in the session" unless a phase grants it.
- **Unbind = revoke.** Removing a subtree from a namespace (conversation
  teardown, job completion, mode change to read-all for writes) revokes
  access; later operations fail with a clear per-path error, never a
  silent no-op.

## 5. Enforcement: nothing bypasses the executor

Every namespace operation is exposed to the model as exactly one tool pair
with stable schemas (`agentfs_read`, `agentfs_write`; `agentfs_list` is
read-only and covered by read):

- `agentfs_read(path, ?since)` → snapshot or error.
- `agentfs_write(path, data, ?create)` → accept/error.

This preserves tool-schema stability across mode changes (the prompt-cache
rule from the WASM plan applies here too): enforcement is at dispatch, by
path, using the live `PermissionPolicy`:

| Access | ordinary mode | read-all mode |
|---|---|---|
| read under own `/agent/<own id>`, `/region` | allowed | allowed |
| read another agent's tree | per-path grant (below) | allowed (read stays read) |
| write `ctl`/`task` on own children | normal unknown-tool policy: ask / explicit rules / `--yolo` | **hard deny** |
| write outside own namespace | denied unless a shared-write subtree was granted | hard deny |

- No namespace path ever implies `LocalControlTool` or any executor bypass.
  The spawn-under-`--yolo` inheritance rules that `delegate` has today are
  the *only* shortcut, and the filesystem path delegates to the same
  scheduler call to inherit exactly those semantics.
- Writes to `task`/`ctl` re-check policy after any approval wait, same as
  tool dispatch elsewhere.
- Per-agent serialization: a child agent's `task` accepts one accepted
  write at a time; the second concurrent write is refused (`busy`), it is
  not queued silently. Queuing and its cancellation semantics arrive with
  Phase N2 and are designed then.

## 6. Phases

### N0 — read-only mount (observation)

Mount `/agent/<id>/{status,events,history,profile}` and `/region/<dir>/summary`
for the *focused* conversation's session, backed by the live session store,
`AgentEventBus` streams, and `RegionRegistry`. `agentfs_read`/`agentfs_list`
land as ordinary tools. Writes do not exist yet.

**Exit gate:** golden tests for tree shape and file contents against a live
scheduler (real `SubAgentScheduler`, fake provider); read-all denies nothing
new (all reads); a stopped/finished job reads coherently; restoring a
session re-mounts persisted agents' history; the architecture suite stays
green and the tree is absent (tools decline) when no session is open.

### N1 — command files (single-owner delegation)

`ctl`/`task`/`result` go live, implemented as thin wrappers over
`SubAgentScheduler.runStandalone`/job APIs — the same code `delegate` calls.
`delegate`/`dispatch`/`continue`/`collect` remain; the filesystem is an
alternative address for the same operations, not a second scheduler.

**Exit gate:** every existing scheduler/delegation test passes unchanged;
file-spawned jobs appear as normal persisted spawn conversations
(`ConversationMetaInput.spawn` path); approval-required spawns surface the
same approval card as `delegate`; cancelling a job via `ctl` joins owned
work (no orphan isolates); nested depth/profile-ceiling rules from
`AgentToolContext` are enforced identically on both paths.

### N2 — agent-to-agent communication

Allow a *running* agent to address child trees it owns: write `task`, poll
`status`, read `result`, bounded `events`. Formalize: per-agent mailbox
serialization, bounded pending queue with cancellation (queue drain on
cancel, no "cancelled" reply while a mutation is admitted), quotas (jobs per
conversation, bytes per mailbox, poll rate), and deadlock rules (an agent
may only block on descendants; cycles are impossible by construction
because the ownership graph is a tree — document and test this).

**Exit gate:** concurrent-conversation tests (two parents, overlapping
children, one cancelled mid-queue); a child's failure surfaces in the
parent's `result` read as an error record, not a hang; quota exhaustion is a
typed error the model can act on; all limits committed in this document's
limits table before merge.

### N3 — join and regions as files

`/join` semantics: re-attach an existing (possibly restored) conversation by
id into the caller's namespace, observation-first, write access only with an
explicit grant. Region tools (`listRegions`/`queryRegion`/`broadcastRegion`)
gain file equivalents under `/region/…` with identical enforcement.

**Exit gate:** restore-then-join equals restore-then-continue byte-for-byte
at the transcript level; a joined agent's mode changes are visible live in
the joiner's `status` reads; region file ops and region tools have parity
tests (same deny/allow decisions on both paths).

### N4 — capability broker bridge (after tin-w4sm Phase 5)

WASM plugin brokered operations (confined file read first) appear as files
under a `/cap/…` subtree, granted per module/conversation, revoked on mode
change. The namespace becomes the uniform grant surface the WASM plan's
Phase 5 already asks for. Not designed here; do not start before tin-w4sm
Phase 5 lands its own gate.

## 7. Failure behavior (fail closed)

| Situation | Required behavior |
|---|---|
| Namespace unmounted (no session) / unknown path | tools decline with a typed error; no fallback to bespoke tools |
| Write denied by live policy (mode flipped mid-wait) | deny, preserve cancellation classification, never auto-retry |
| Child crash mid-`result` | `status` = error with scheduler's error record; `result` read returns the error, not stale text |
| Malformed `ctl` verb / oversized write | typed protocol error; bounded (numbers per limits table) |
| Session restore cannot remount a referenced agent | fail the join explicitly; never silently drop the subtree |

## 8. Testing boundaries

- **Fake scheduler** for path/permission matrices (no providers).
- **Real scheduler + fake provider** for N1/N2 lifecycle gates.
- **Fake clock** for poll/rate limits; no real sleeps in tests.
- Permission tests assert *decisions and file contents*, not just tool
  return codes.
- The TUI consumes `AgentEventBus` as today; namespace mirror code gets its
  own golden tests and must not be a required dependency of the render path
  (native-free unit jobs stay native-free and namespace-free).

## 9. Limits table (fill per phase gate; a phase without numbers does not ship)

| Limit | Value | Set in |
|---|---|---|
| events ring size per agent | TBD | N0 |
| history excerpt size | TBD | N0 |
| mailbox queue depth / bytes | TBD | N2 |
| poll rate cap per caller | TBD | N2 |
| jobs per conversation | TBD | N2 |
| `ctl`/`task` max write size | TBD | N1 |

## 10. Completion checklist

- [ ] One address scheme; no second scheduler; `delegate` parity tests green.
- [ ] Every file op rides `ToolExecutor` with live policy; read-all denies
      writes regardless of grants.
- [ ] Namespaces are constructed per conversation; no global agent listing
      unless granted.
- [ ] All limits committed above before the phase merges.
- [ ] Restore/join behavior is explicit-fail, never silent.
- [ ] Cancellation joins owned work on both scheduler and namespace paths.
