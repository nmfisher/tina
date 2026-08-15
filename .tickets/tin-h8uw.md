---
id: tin-h8uw
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: proposal
priority: 2
assignee: Nick Fisher
tags: [environment, agent, index, bootstrap, design]
---
# Environment Agent — persistent environment record + background setup agent

## Context

An agent that updates code needs the same environment on every launch: dependencies installed, git identity + SSH keys loaded, GitHub auth, build passing, test baseline known, toolchain present. Today every agent discovers all of this from scratch — AGENTS.md plus whatever the machine happens to have. The steps are the same every time, and re-discovering them is slow, wasteful, and error-prone (an agent misreads a failing test if it does not know the pre-existing baseline).

We want:

1. A **user-editable environment record** (declarative): toolchain, setup commands, build/test commands, auth references, test baseline.
2. A background **environment agent** that initializes the record on first tina run in a repo, keeps it fresh, and RUNS the setup (deps, build, test, git/SSH/GitHub).
3. **Warm load** on subsequent runs: the record + latest verified snapshot load fast, and verified facts inject into the agent system prompt.

## Design decisions (approved by user, 2026-08-15)

1. **The environment record lives alongside the summary index** — it is a *measured region* of the /index staleness dance, because it may need changing when the code changes (new dependency in a manifest, changed build command, new test baseline).
2. **Trigger:** first run in a repo initializes it (background). After that, the environment agent decides if/when to update — staleness monitoring is its job; the /index dance flags the record stale, the env agent acts on it.
3. **No query interface for now** (no /env slash command yet — the persistent session can be queried later).
4. **The environment agent RUNS things** — dependency install, build, test, git identity setup, SSH key loading, GitHub auth. It is a doing worker, not just an oracle. Secrets never live in the record — only references to auth sources (e.g. "use the loaded ed25519 key").

## Open questions for the proposal

- How does the summary fleet launch today? (summary_runner.dart / SummaryIndex.refresh — ephemeral composition pattern) — reuse for the env agent's background job?
- How does the /index staleness dance measure regions? How does the env record become a measured region (same partition/allocations machinery)?
- Where does the snapshot cache live? (.tina/ sidecar convention — see .tina/summaries/allocations.json)
- How do permissions apply when the env agent runs commands? (project_trust, permission policy, --yolo/--allow paths)
- Record file format + location (repo root, versioned, like AGENTS.md). Contents: toolchain, setup commands, build/test commands, auth references, test baseline.
- Warm load: what exactly loads on subsequent runs (record + snapshot + system-prompt injection into the environment block — see system_prompt.dart)?
- First-run trigger: where in the app does the background env agent launch (composition? TUI startup? headless)? Scheduler job vs ephemeral fleet?
- How does the env agent decide staleness (hash-based: manifests, lockfiles, tool versions)?

## Acceptance criteria

- Write the design proposal to docs/proposals/environment_agent.md. NO code/test changes — proposal only.
- Cite the code you read (file:line).
- Update ticket status with tk (start when beginning, close when done).
- Commit all work locally, raise a PR when finished. Never merge.
- Simplified technical English.

## Design revision 1 (2026-08-15) — single record

The user revised the design: there is **only ONE environment record**, not two (no separate human-editable spec + machine-written snapshot). The record is one file. If no record exists on first load, the environment agent populates it from its measurements. Revise the proposal accordingly:

- Merge the two-artifact design into one record file. The agent maintains the observed-state parts; the user can edit anything.
- Re-check the affected parts against the new shape: the index region (what digests it measures), warm load (what injects into the system prompt), and the trust gate (unchanged risk — setup lines are execution).
- Note the accepted tradeoff: machine-observed state lives in a versioned file (single-machine assumption).
