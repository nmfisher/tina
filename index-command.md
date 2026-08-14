---
layout: page
title: The /index command
permalink: /index-command/
---

# The `/index` command

`/index` builds and maintains a **per-directory summary index** of your
repository. For every folder it watches, tina writes a short, plain-language
summary of what lives there — the major types, the entry points, how the pieces
fit together. Those summaries power the **region agents**: instead of asking the
main agent to re-read the whole repo every time, tina can route a scoped
question to a small, fast agent that already knows one area cold.

## What gets indexed

On a normal (TUI) session the **first** `/index` asks the main agent to design
the layout: it reviews your folder structure and decides which folders deserve
their own summary — skipping trivial ones, merging closely-related ones, splitting
large dense ones. Whatever it proposes becomes **the partition**: from then on,
`/index` indexes exactly those folders and nothing else.

When you never propose a layout (for example, a headless run, or if the proposal
turn allocated nothing), tina falls back to a deterministic **default partition**:

- every top-level directory (except `.dart_tool`, `build`, `dist`, and hidden
  folders), plus
- every `packages/*/lib` directory.

Once any layout has been approved, it **replaces** the default — the default
partition is only used until you propose something.

## Using `/index` in the REPL

Type `/index` and press enter. tina probes the repository with plain `git` (no
LLM calls) to decide what to do, then acts on one of four states:

| State | What `/index` does |
|-------|--------------------|
| **First run** | The main agent designs the region layout (a proposal turn). Run `/index` again to approve it and generate the summaries. |
| **Everything stale** | Re-summaries all watched folders. |
| **Partly stale** | Reports which folders drifted and re-summaries *only* those. |
| **Up to date** | Reports "up to date" and asks before re-running everything. |

### The first-run flow

1. You run `/index`. tina says it has no index yet and hands the main agent a
   **proposal turn**.
2. The main agent inspects the repo and calls `allocate_region` for each folder
   it wants summarized, then reports the proposed layout.
3. You run `/index` **again**. tina shows the proposed regions and asks
   **"Summarize the N proposed regions? [y/N]"**.
4. You approve → the fleet generates the summaries. Decline → nothing is written.

If a proposal turn runs but allocates nothing (the agent found nothing worth
indexing, or every region was later deleted), tina does **not** loop forever.
The next `/index` offers to index the default partition instead — **[y/N]**.

### Staleness (how tina knows what changed)

A folder is considered **stale** when either:

- its committed tree changed (`git` sees a different tree at `HEAD`), **or**
- its working tree changed — an edit, a new untracked file, or a staged change
  inside that folder, even if you have not committed yet.

So you do not have to commit before re-indexing: edit a file, run `/index`, and
that folder gets refreshed. Commit it afterward and it becomes stale again, so a
later `/index` keeps the summary in step with `HEAD`.

> Note: staleness tracks the **set of changed files** in a folder, not the exact
> bytes of already-dirty content. Re-editing a file you have not committed since
> the last index will not by itself re-trigger a re-summary until the set of
> changed files changes (a new untracked file, a new modification, or a commit).

## It runs in the background

In the TUI, `/index` launches the summarization fleet and **returns immediately**.
Your input stays live — you can keep chatting, ask questions, or scroll while the
summaries are generated. Progress and the final "Indexed N directories" notice
stream into the chat.

- **Cancel:** press **Esc** twice (Esc-Esc) to cancel an in-flight index. The
  first Esc arms the cancel; the second confirms it.
- **Concurrent runs:** starting a second `/index` while one is already running
  warns you it is busy and does not launch a second fleet.

## Spend cap

`/index` uses tokens (it spins up summarizer agents). If your session's token
spend ceiling has already been tripped, `/index` refuses to run and tells you to
raise the cap (or check `/spend`) first — it will not be the one loophole around
the limit.

## Headless / non-interactive use

To index once and exit — useful in CI or a script — pass the command as a prompt:

```sh
tina --prompt /index
```

There is no interactive main agent here, so the **default partition** is used
(unless you already approved a layout in a previous TUI session, in which case
that layout is reused). The run blocks until the summaries are written and prints
its "Indexed N directories" result before exiting. There is no background mode
and no Esc-to-cancel in this mode.

## Where the summaries live

`/index` stores everything in a **separate git repository** at
`.tina/summaries` inside your project:

- `manifest.json` — the index: one entry per watched folder recording the commit
  it was summarized at, the tree hash, and the summary file.
- `<folder>.md` — the human-readable summary for each folder (folder names are
  URL-encoded, e.g. `packages/foo/lib` → `packages%2Ffoo%2Flib.md`).
- `allocations.json` — your approved region layout (the partition).

The summaries repo is independent of your project's history, so indexing never
pollutes your commits. Removing a watched folder from disk marks its summary for
deletion on the next `/index`.

## Region agents: the payoff

Once summaries exist, the main agent can spin up a **region agent** for any
watched folder — a small, fast agent pre-loaded with that folder's summary (at
session start, with zero extra LLM calls) and able to answer questions scoped to
that area:

- `query_region` — ask one region a question.
- `broadcast_region` — ask every region at once (e.g. "which part owns auth?").
- `list_regions` / `read_summary` — see what is indexed and the stale state.
- `allocate_region` / `forget_region` — grow or shrink your layout; the change
  takes effect on the next `/index`.

If a region's underlying code has drifted, `list_regions` flags it stale so you
know to run `/index` before trusting its summary.
