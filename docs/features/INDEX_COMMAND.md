# /index

`/index` classifies programming and markup languages in the project directory tree. It does
not create summaries, propose regions, run setup, or classify frameworks, build
systems, test systems, or target platforms.

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

Extension classification needs no API key or network access. It maps the final
filename extension to a language, with per-file evidence. Unknown extensions,
extensionless files and ambiguous entries such as `.h` and `.m` remain unknown;
there is no automatic model fallback. `/index jev` uses the configured Typesafe
model (default `jev-latest`); set its API key in `/settings` or `TYPESAFE_API_KEY`.
Neither implementation uses the chat model. The default source supplies filenames only, applies Git ignores
and collection exclusions, and requires a Git repository. Input selection and
freshness are source policy; only the classifier decides the language labels.

See [project classification](project_classification.md) for limits and storage,
[classifier](../../packages/classifier/README.md) for the generic tree API, and
[file_tree](../../packages/file_tree/README.md) for shared filesystem machinery.
