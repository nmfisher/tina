# /index

`/index` classifies programming and markup languages in the project directory tree, then
framework and tooling signals per directory. It does not create summaries,
propose regions, or run setup.

1. Discover directories down to the leaves using the source's file inventory.
2. Use the language classifier to classify each directory's direct files.
   Independent directories can run in parallel. Files directly in parent
   directories are included too.
3. Walk back up the tree, merging each node's findings with its children's
   language results. Merging adds no new language guesses.
4. Save local and merged results in `.tina/classifications`.

Unchanged classifications restore from disk. If `docs/user` changes, only its
local classifier reruns; `docs/dev` remains reusable. Changed findings propagate
through `docs` to the root. If the consumed output is unchanged, propagation
stops. Failed children block their ancestors; incomplete coverage stays visible.

- `/index`: use local extension rules, restoring current results and classifying missing or stale inputs.
- `/index status`: validate saved results without model calls or writes.
- `/index refresh`: rerun language classification and rebuild merged results.
- `/index extensions`: explicitly select the local extension classifier.
- `/index jev`: use the configured Typesafe/JEV classifier instead.
- `/index jev status` and `/index jev refresh`: inspect or rebuild JEV results.

Double-Esc cancels interactive work and releases input. Headless Ctrl+C cancels
the same workflow. Completed checkpoints survive cancellation. Headless runs
with missing, failed or incomplete results exit nonzero.

While an interactive `/index` runs, the background job frees the input and the
status strip beneath it paints an `indexing · 12/54` line: one count per
classifier task (locals plus per-level merges, summed across the language,
framework and tooling trees), a spinner while the total is not announced yet,
and removal when the run completes, fails or is cancelled. The strip line is
display-only — the dim transcript progress lines and the final report are
unchanged. Headless runs have no strip.

Extension classification needs no API key or network access. It maps the final
filename extension to a language, with per-file evidence. Unknown extensions,
extensionless files and ambiguous entries such as `.h` and `.m` remain unknown;
there is no automatic model fallback. `/index jev` uses the configured Typesafe
model (default `jev-latest`); set its API key in `/settings` or `TYPESAFE_API_KEY`.
Neither implementation uses the chat model. The default source supplies filenames only, applies Git ignores
and collection exclusions, and requires a Git repository. Input selection and
freshness are source policy; only the classifier decides the language labels.

## Classifier programs

`/index` runs its stages as a classifier program on the attractor engine
(`type="classify"` nodes): `language` first, then `details` (framework and
tooling in one stage). The built-in program sequences
`start → language → details → exit`.

The program is resolved per run, in order:

1. `<repo>/.tina/programs/index.dot`, else the *single* `*.dot` in that
   directory when unambiguous;
2. `~/.tina/workflows/index.dot` (global default);
3. the built-in program — `/index` never runs "no program".

An invalid program file fails fast: the report carries the file's
diagnostics under `program`, no store is opened and no classifier runs —
the built-in never masks a broken file. Progress lines prefixed
`Program <name>: stage <id>` trace the walk; a stage that fails outright
ends the run (later stages are skipped), while per-task failures inside an
attempted stage leave downstream stages running. Edit programs with
`/workflow edit <name>` — workspace programs open first and save back to
`.tina/programs/`. See
[the proposal](../proposals/hierarchical_classifiers.md) for the routing
rules and decisions.

See [project classification](project_classification.md) for limits and storage,
[classifier](../../packages/classifier/README.md) for the generic tree API, and
[file_tree](../../packages/file_tree/README.md) for shared filesystem machinery.
