# WASM plugin support: phased implementation plan

Status: proposal; no WASM implementation is included in this PR.
Updated: 2026-09-12.
Baseline: main at `43e60e1` (v0.6.13), including the merged plugin runtime
from PR #49 and its restoration/cleanup fixes. Implement against that baseline
or newer, not the older code on this proposal branch.

## 1. Outcome and reading order

Let users explicitly enable an external WebAssembly tool without recompiling
Tina. Keep trusted built-in Dart plugins and their existing composition model.
Mount external tools through `PluginRuntime`, and execute every model tool call
through the normal executor, permissions, phase gates, and cancellation path.

Read sections 2–5 before starting a phase. Implement phases 0–4 in order;
together they are the first shippable version. Phases 5–6 are separate extensions.
Each phase has an exit gate. Do not mark a phase complete because its happy-path
demo works; all of its required checks must pass. When an assumption fails,
update this document before implementing a different contract.

| Phase | Deliverable | May ship independently? |
| --- | --- | --- |
| 0 | Native runtime and worker feasibility evidence | Internal prototype only |
| 1 | Validated manifest, ABI, and pure module fixtures | Internal only |
| 2 | Async activation, ownership, cancellation, and rollback | Built-in behavior must remain compatible |
| 3 | One external tool through the real agent path | Experimental until phase 4 passes |
| 4 | Packaged, tested headless and TUI support | First supported WASM release |
| 5 | Revocable host capabilities | Separate feature after phases 0–4 |
| 6 | Guards, result hooks, and observers | Separate feature after phase 5 |

## 2. What the existing plugin runtime actually guarantees

These are current implementation facts, not proposed WASM behavior:

- `PluginDescriptor` factories are synchronous. `PluginRuntime.activate()`
  currently calls the synchronous path and awaits rollback on failure; it does
  not await asynchronous factories. `ProjectToolScope` has synchronous
  construction/activation sites that a migration must account for.
- The runtime validates descriptor IDs, service dependencies, provider
  selection, cycles, and decoded configuration before calling factories.
  Factories then run in dependency order. A later factory can fail after earlier
  factories have acquired resources; rollback handles that partial activation.
- Services are Dart objects addressed by `ServiceKey`. Contributions are objects
  selected by typed assembly helpers. Neither mechanism is a security boundary.
- Registration ownership revokes contributions and reserves their IDs through
  cleanup. Scope teardown releases owned resources; borrowed resources stay with
  their owner. These mechanisms do not automatically join arbitrary native work.
- `ToolExecutor` owns per-call enforcement. Mandatory policy and phase guards
  precede extension guards. Arguments are sealed, execution hooks own their
  delegated work, and guard exceptions deny execution.
- `LocalControlTool` is significant: the executor bypasses the ordinary approval
  question for it after applying mandatory gates. External modules must never
  acquire that marker merely by declaring a name or manifest field.
- `PermissionPolicy.mode` is live mutable state, including for derived policies.
  Read-all is a hard execution boundary, not an approval preference. Tool
  declarations remain stable when the mode changes; enforcement happens at use.
- Driver selection applies to new and restored conversations, including nested
  agents. External tools must reach those paths through existing composition.
- Trusted Dart factories, hooks, and observers can execute arbitrary Dart code.
  Observer exception containment does not prevent a callback blocking the event
  loop. Claims that a Dart plugin cannot influence a running turn or has no
  authority beyond its API are incorrect.

Relevant sources under `packages/`: engine `src/runtime/`,
`src/agent/tool_executor.dart`, `tool_guards.dart`, `tool_hooks.dart`,
`project_tool_scope.dart`, and `src/permissions/policy.dart`; app
`src/composition/execution_runtime.dart` and `src/persistence/session_restore.dart`.

## 3. Fixed scope and safety contracts

### Two plugin tiers

Built-in Dart plugins remain trusted code with access to Dart interfaces.
WASM plugins receive only serialized inputs and explicitly implemented imports.
A manifest never grants authority by itself.

The first release supports **one pure tool per module**, with JSON input and
output, bounded logging, and that module's own configuration. It has no WASI,
filesystem preopens, network, environment, clock, randomness, subprocesses,
shared memory, arbitrary service keys, guards, hooks, observers, or custom
agent drivers. Reject declarations for unsupported features; do not ignore them.

Use a `normalize_text` example that transforms text supplied in its input.
Keep `write_summary` in Dart. It obtains real Git hashes, reads the clock,
writes atomically, and is composed through `writeSummaryToolServiceKey`.
Porting it would require capabilities and services outside this first release.
A later conversion must preserve host-authored tracking metadata.

No automatic repository discovery, downloads, marketplace, component model,
WasmGC authoring promise, live plugin replacement, or automatic retry of failed
module execution is part of phases 0–4.

### Execution and cancellation

Run Wasmtime via its C API in a **supervised worker process**, not in the
TUI/agent isolate. Start with one worker/store/instance per module per conversation
and serialize calls within that worker. Bound the number of workers and queued
calls; cancellation must also remove queued work. Do not share mutable instances
between agents with different policy contexts. Immutable verified module bytes
may be reused; process startup/compilation cost must be measured.

The worker can be a private entry point of the shipped executable. It must start
without initializing the terminal, providers, or a normal conversation. Use
private pipes, a sanitized environment, no inherited credentials, and no shell.
Native handles stay inside the worker. The supervisor owns process lifetime and
bounded message framing. Child stderr and module logs are bounded diagnostics,
not protocol messages or control sequences to print directly to the terminal.

The process boundary contains worker crashes and lets the supervisor terminate
stuck native calls. It is not an OS filesystem sandbox; guest authority is
restricted by WASM memory/import validation and, later, the host broker. Do not
claim this protects against every native runtime vulnerability or machine-wide
resource exhaustion.

Use fuel and memory limits for guest execution, plus a supervisor wall-clock
deadline for every preparation, activation, call, and shutdown operation.
Deadlines must include guest allocation/free/config/start/stop, not just the tool
export. The supervisor remains responsive even if a worker's FFI call blocks.
On cancellation or deadline expiry: close admission for that call, revoke any
host operation authority, terminate the worker, escalate termination if needed,
and await process exit and pipe cleanup. Mark the instance unavailable. Keep its
tool declaration stable and return a clear error for subsequent calls; recovery
requires an explicit new instance/session, not silently replaying the request.

Epoch interruption can optimize cooperative shutdown later; it is not the only
cancellation mechanism. It cannot interrupt arbitrary blocking host functions.
Do not return "cancelled" while a worker still owns an admitted mutation.
A failure to confirm exit is a teardown error that blocks reuse of the instance.

### Fail closed for explicitly enabled plugins

| Situation | Required behavior |
| --- | --- |
| No external plugins configured and native runtime absent | Normal Tina startup; no native runtime load required |
| Explicitly configured plugin missing, invalid, incompatible, or unable to start | Fail that composition with plugin ID and reason; await cleanup |
| ABI violation, worker crash, deadline, or malformed result during a tool call | Error result; terminate unusable worker; do not rerun automatically |
| Future configured guard cannot load or fails at execution | Fail composition or deny the protected call; never silently omit the guard |
| Normal user cancellation | Preserve cancellation classification; do not turn it into a retryable provider error |

Do not downgrade an explicitly enabled plugin into an optional warning. A plugin
is disabled only by explicit configuration before activation.

### Permissions and caching

Every external tool uses a host-assigned name and the normal policy/phase gates.
Reject collisions with built-in tool names, contribution IDs, and reserved
service namespaces. Modules cannot replace `read`, impersonate `git`, provide a
policy service, set approval defaults, or declare themselves local control tools.

For the first release, external tools use the unknown-tool policy default:
ask in ordinary mode (subject to explicit rules and `--yolo`), and hard-deny in
read-all. Even the pure example is not automatically added to `_readOnlyTools`.
A later read-only classification must be host-verified and separately designed.

Mode changes must not reload plugins or add/remove tool schemas from the model's
tool list. Check live policy at dispatch, including after approval waits. Phase 5
adds live authorization of every host operation; mount-time grants are never a
substitute. This preserves stable upstream prompt/tool cache prefixes.

## 4. Boundaries that make testing possible

Keep generic lifecycle code independent of Wasmtime, IPC, and terminal code.
The following are proposed responsibilities; names can follow local conventions:

| Area | Owns | Must not own |
| --- | --- | --- |
| Engine runtime | Sync/async factory contract, graph validation, activation/rollback | Native loading, manifests, WASM exports |
| App manifest/preparation layer | Explicit selection, bytes/digests, manifest validation, descriptor construction | Executing guest code on the main isolate |
| Worker client interface | Prepare/start/call/stop results, cancellation, process ownership | Approval decisions or terminal rendering |
| Native worker implementation | Wasmtime store, ABI memory checks, bounded execution | Direct project capabilities, credentials, provider objects |
| App tool adapter | Schema, normal Tool API, result/error mapping, owning call context | Bypassing ToolExecutor |
| Later capability broker | Current policy, confinement, resource grants, mutation ownership | Trusting worker-supplied policy/session identity |
| CLI/TUI composition | Explicit plugin selection, diagnostics, worker executable path | FFI handles or separate enforcement implementations |

Inject the worker client, launcher, clock/deadlines, and later broker. Unit tests
use fakes to exercise scheduling and failure mapping. Native integration tests
use the shipping Wasmtime implementation: another interpreter cannot establish
FFI safety, ABI compatibility, or cancellation correctness.

If a new package is needed for native code, add it to the architecture inventory
and CI matrix in the same change. Engine runtime unit tests and terminal-free
app unit tests must remain runnable without loading the native library.

## 5. First-release manifest and ABI

### Manifest

A plugin directory contains `plugin.json` and `plugin.wasm`. A trusted launch
setting such as `--wasm-plugins <dir>` explicitly selects a directory; merely
opening a repository must not execute its plugins. Resolve paths and read bounded
files once, retain those exact bytes through preparation/activation, and validate
any configured digest against them. Do not validate one path then reopen changed
bytes at activation. A digest beside an attacker-controlled module establishes
no publisher identity; distribution signatures are outside the first release.

```json
{
  "id": "com.acme.normalize-text",
  "api": 1,
  "module": "plugin.wasm",
  "tools": [{
    "name": "normalize_text",
    "description": "Normalize text supplied in the input.",
    "inputSchema": {
      "type": "object",
      "properties": {"text": {"type": "string"}},
      "required": ["text"],
      "additionalProperties": false
    }
  }],
  "config": {},
  "capabilities": []
}
```

Require exactly one tool and the literal local module filename for API 1.
Validate IDs, tool-name grammar/length, supported schema forms, configuration
size, and all unknown fields. No arbitrary `provides`/`requires` strings become
Dart service keys. The host supplies fixed descriptor dependencies and a stable,
provider-compatible external tool name; detect naming collisions before mounting.
Persist selected plugin IDs and content digests for continuation. If continuation
cannot restore the same explicitly selected plugins, fail with an actionable
error rather than silently changing the tool set.

### Core WASM ABI 1

Only a single exported, non-shared wasm32 memory is allowed. Disable unsupported
WASM features and reject unexpected imports/exports/signatures and module start
sections. WASI imports are not linked. The explicit `tina_start` export controls
guest startup; instantiation is still fallible even without a start section.

These are exact export signatures (all names refer to module exports):

```text
memory

tina_abi_version() -> i32                         # exactly 1

tina_alloc(byte_len: i32) -> i32                  # nonzero buffer offset; 0 = allocation failure

tina_free(ptr: i32, byte_len: i32) -> ()

tina_config(input_ptr: i32, input_len: i32) -> i32 # 0 = success; nonzero = error code

tina_start() -> i32                               # 0 = success; nonzero = error code

tina_stop() -> i32                                # 0 = success; nonzero = error code

tina_tool_execute(input_ptr: i32, input_len: i32,
                  result_record_ptr: i32) -> i32   # 0 = result written; nonzero = error code
```

The only initial guest import is `tina.log(level:i32, ptr:i32, len:i32) -> ()`.
It has a validated level, bounded UTF-8 payload, and per-call output budget.
The guest does not import alloc/free from the host.

The host allocates the input buffer and an eight-byte result record through
`tina_alloc`. Input is UTF-8 JSON. The result record is two little-endian u32
values `(payload_ptr, payload_len)`, pointing to a separately guest-allocated
UTF-8 JSON payload: `{"content":"...","isError":false}`. Status zero means
this envelope must be present and valid; nonzero status is an ABI operation error,
not a pointer. Trap and transport errors are distinct from returned status codes.

Require disjoint input, record, and payload regions. The guest lends result
memory until the host calls `tina_free`; it must not free or reuse it earlier.
The host copies validated output before freeing buffers, then frees each owned
allocation exactly once using its original length. On trap or invalid memory,
discard the instance/process; do not invoke guest cleanup to repair an invalid ABI.
On an ordinary nonzero execute status, the guest retains responsibility for any
internal temporary allocation; the host only frees its known input/record buffers.

Treat pointers and lengths as untrusted unsigned offsets, never native addresses.
Check `ptr <= memory_size` and `len <= memory_size - ptr` before every copy;
validate the record before reading it. Enforce host byte limits before allocation
and decoding. Reacquire the memory base after guest calls that may grow memory;
never retain an old native pointer across such calls. Invalid UTF-8, overlap,
oversized output, unknown result fields, and wrong JSON types are protocol errors.
Apply the same checks to logging. Errors must identify the plugin and operation
without dumping unbounded input, secrets, or raw guest-controlled terminal escapes.

Phase 0 measurements determine committed host defaults for module/input/output
sizes, JSON depth, log volume, memory, fuel, wall time, worker count, and queues.
Plugins may request stricter limits later; they cannot raise host ceilings.
No supported release may leave these limits unspecified or unlimited.

## 6. Implementation phases and exit gates

### Phase 0 — prove the native execution model

Build a disposable prototype with a pinned Wasmtime version, reproducible source
and license records, minimal C declarations, and the proposed worker transport.
Use Rust/core WASM or hand-written WAT fixtures; Dart-to-Wasm and components are
not prerequisites. Decide between a maintained binding and a small generated C
binding based on required APIs, not package popularity alone.

Prove worker startup, successful execution, trap handling, memory limits, an
infinite loop, parent-driven termination, and worker exit. Measure compile/start
latency, call latency, idle memory, maximum-worker memory, and artifact size on
macOS ARM64, Linux x64, and Linux ARM64. Verify the native dependency's signing
and loading behavior with Tina's packaged layout. Wasmtime's compilation memory
is not bounded merely by a guest linear-memory limit; set module size/concurrency
ceilings and record residual host resource limits.

**Exit gate:** record exact versions, commands, target results, limits, and timing
thresholds in a checked-in results document. All three targets must prove a stuck
worker can be terminated without blocking the parent. Do not proceed by running
FFI on the UI isolate if packaging or cancellation is difficult.

### Phase 1 — validate bytes and implement ABI 1

Implement manifest parsing and native preparation separately from activation.
Preparation parses/compiles all selected modules and validates imports, memory,
exports, feature restrictions, and manifest/config shape. It executes no guest
exports and instantiates no module. Own preparation workers/resources immediately;
if preparation of any module fails, release all prepared resources.

Runtime descriptor graph/config validation must also finish before any factory
runs. Only after **all** preparation and graph validation succeed may activation
begin. Keep the prepared bytes/artifacts in host-owned memory or private storage;
never deserialize untrusted precompiled native artifacts as if they were WASM.

Implement ABI 1 with valid fixtures and deliberately malformed modules. Static
validation cannot prove an export returns version 1 or that `tina_start` succeeds:
those are activation-time checks, with rollback, in phase 2.

**Exit gate:** tests cover invalid manifests, duplicate/reserved names, digest
mismatch, replaced source bytes, bad imports/signatures, start sections, bad
pointers/lengths, overflow, overlap, memory growth, invalid UTF-8/JSON, oversized
results, allocation failure, and bounded logs. A malformed later module must
fail preparation before an earlier plugin factory runs. ABI tests execute the
real native worker, not just Dart mocks.

### Phase 2 — add asynchronous lifecycle support

Add an explicit async factory contract while retaining synchronous built-in
factories. `activate()` must actually await each factory in dependency order.
`activateSync()` must reject a graph containing async factories during validation,
before any factory runs. Keep exactly-once activation and deterministic ordering.
Audit `ProjectToolScope` and application composition call sites: mount prepared
external adapters at an async composition boundary; do not insert async factories
into an unchanged synchronous constructor.

Define the race between activation and disposal: close admission immediately;
cancel and join activation work before releasing its resources. A factory
finishing after closure cannot publish services/contributions. Concurrent dispose
calls share one completion. A failed runtime remains terminal.

For each module, arm process ownership before instantiation. Check ABI version,
configure the module, and call start under deadlines. Only then publish its tool
adapter. These steps can fail after other plugins activated: await complete
rollback and preserve the original error. Failed start must not leak a worker.

Normal teardown order: close adapter admission; cancel queued/running calls;
join them; attempt bounded stop for a still-healthy instance; terminate and await
worker exit; release transport/prepared resources and registrations. Cleanup must
continue if stop traps. Never free a store while a call can still access it.

**Exit gate:** existing runtime tests pass, plus mixed sync/async ordering,
pre-factory sync rejection, config/start/version failure, later-factory rollback,
disposal during activation/call/stop, failed cleanup, exactly-once disposal, and
no orphan workers. Assert event ordering and resource ownership, not just counts.

### Phase 3 — integrate one pure tool end to end

Load the `normalize_text` fixture through normal app composition. Exercise its
host-assigned schema and `WasmTool` through a real agent/executor, including
approval, denial, phase gating, cancellation, output mapping, and session history.
Use the same composition for headless, TUI, nested agents, and restoration.
Keep worker instances conversation-owned even when built-in project tools are
borrowed. Record explicit IDs/digests in session metadata and define restore
errors for changed or missing plugins.

**Exit gate:** in-process integration tests establish policy behavior, including
read-all, remembered/static rules, `--yolo`, and switching modes while approval is
pending. Tool schemas must be byte-for-byte stable across mode changes. Test two
concurrent conversations, cancellation of a queued call, a dead worker, continued
history, and restoration with changed/missing bytes. A cancelled/crashed call
must not enter an automatic provider retry ladder.

### Phase 4 — package and release the first version

Integrate the pinned native runtime and worker entry point into build hooks and
all three release targets. Define deterministic absolute library resolution from
the bundle; do not load from the working directory or arbitrary system search
paths. Sign/notarize any added macOS native binaries and include their installed
layout in updater/installer coverage. Update feature documentation with supported
ABI, limits, explicit loading, failures, and restart behavior.

Run root and affected package analysis/tests plus the architecture check. Add
required native integration jobs on each target; they must fail rather than skip
when a configured plugin cannot run. Native-free unit jobs should remain native
free. Measure results against phase 0's committed thresholds.

**Exit gate:** installed bundles execute a fixture through headless and TUI
paths, cancel an infinite loop without losing keyboard responsiveness, and exit
without orphan workers. Verify valid/missing/incompatible libraries, absent and
explicitly configured plugins, checksums/signatures, and continuation. All target
jobs and existing regression suites pass. Only now advertise WASM tool support.

### Phase 5 — add live, revocable host capabilities

This phase is a separate extension. Keep direct WASI preopens and raw host file
descriptors out of the guest: mount-time access cannot implement Tina's changing
permission modes. Start with one narrow operation, such as a confined file read,
through a host broker. Do not add shell, network, generic service lookup, or
mutations in the same step.

Define an async request/response bridge before adding imports that need host
work. Use a proven C API async bridge or an explicitly versioned resumable guest
protocol; demonstrate cancellation and buffer ownership first. A synchronous
Dart callback that waits for the parent event loop is not a valid bridge.

The broker derives module/conversation/call identity from the owned transport,
not guest payload fields. It intersects explicit user grants, declared requests,
current policy, phase, confinement, and cancellation on each operation. Permission
to execute a tool is not blanket approval for its requested filesystem actions.
Use normal approval semantics for the concrete host operation and recheck after
approval waits. No broker operations during config/start/stop or observer events.

When adding mutations later, serialize authorization-to-commit with mode changes
and existing mutation locks. Define a clear commit point: operations committed
before revocation remain committed; admitted-but-uncommitted work is cancelled or
rejected. Mode changes revoke pending grants/handles, and no new mutation may
commit under the old policy. Completion/cancellation must join host work before
releasing its owning call. Do not give the guest lasting OS handles.

**Exit gate:** tests switch to read-all before dispatch, during approval, during a
queued operation, and before mutation commit. Test forged call IDs, cross-agent
requests, traversal/symlink escape, late replies, revoked grants, and cancellation
with host work in flight. Assert the file contents as well as reported denials.
Policy changes must still leave model tool schemas and prompt prefixes unchanged.

### Phase 6 — add extension hooks one interface at a time

Guards require an asynchronous guard contract: today's `ToolGuard.block` is
synchronous and cannot wait for the worker without blocking the agent. Preserve
mandatory guard order, argument sealing, fail-closed behavior, cancellation, and
the final policy check immediately before dispatch. Bound guard latency; invalid,
trapped, unavailable, or timed-out guards deny the call. Never skip them to keep
execution moving.

Then consider result hooks and observers separately. Result hooks retain the
existing verdict semantics and cannot authorize a side effect. Observer delivery
needs a bounded queue and documented overflow behavior; slow observers cannot
block execution, issue broker operations, or become a substitute security guard.
All these calls share the instance's serialization and teardown rules. Keep
AROUND hooks, arbitrary services, and agent drivers outside this phase.

**Exit gate:** real native tests cover guard failures, denial ordering, mode
changes during awaited guards, slow observers, queue overflow, concurrent calls,
and disposal while each extension is active. Benchmark overhead against phase 0
results before enabling guards in the normal tool path.

## 7. Completion checklist and evidence

The implementation owner records each phase's commit, commands, test counts,
failures/skips, platform evidence, and measured limits. An unrun native check is a
blocker to its phase, not a passing unit-test substitute. Each implementation PR
names its phase, keeps later features out, and updates the results record.

The first-release acceptance checklist is:

- [ ] Phases 0–4 exit gates passed on all supported targets.
- [ ] No guest code or potentially blocking FFI executes on the agent/UI isolate.
- [ ] Explicit plugin failures cannot remove enforcement silently.
- [ ] Every acquisition has an owner; cancellation and teardown join workers.
- [ ] Manifest/ABI validation and activation failure handling are distinct.
- [ ] External tools obey live permissions without changing cached schemas.
- [ ] No unsupported capabilities, services, hooks, or discovery are enabled.
- [ ] Pure fixture ships with an authoring example and reproducible build steps.
- [ ] Installer, updater, native loading, and TUI cancellation are tested.

## 8. References and remaining research

Wasmtime exposes async calls and yielding in its
[C API](https://docs.wasmtime.dev/c-api/async_8h.html). This is an available
mechanism, not proof that an arbitrary Dart binding exposes it safely. Its store
and argument lifetime restrictions must be respected by any later async bridge.
See also [execution interruption](https://docs.wasmtime.dev/examples-interrupting-wasm.html)
and [blocking host-call limitations](https://docs.wasmtime.dev/api/wasmtime/struct.Config.html#interaction-with-blocking-host-calls).

Phase 0 must settle the pinned version/binding, per-target packaging, measured
limits, and worker overhead. Later decisions include the first broker operation,
read-only external tool classification, distribution trust anchors, and whether
component tooling justifies a new ABI. None is permission to widen API 1.
