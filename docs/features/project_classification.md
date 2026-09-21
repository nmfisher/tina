# Project classification

`/index` classifies languages, frameworks and tooling, from the leaves of the directory
tree back to the root. `/index status` validates/restores saved results without
model calls or writes. `/index refresh` reruns classification. The same commands
work with `tina --prompt`; incomplete headless runs exit nonzero. TUI double-Esc
and headless Ctrl+C cancel. Nothing runs on startup. Indexing does not launch
summary agents, region-layout proposals, setup or experts.
Language detection defaults to local extension matching. `/index jev` selects
the model-based language implementation; both methods accept `status` and
`refresh`. Framework and tooling classifications use Typesafe/JEV in either mode.

The reusable API is documented in [classifier](../../packages/classifier/README.md).
The project feature is an application recipe built on that API. Paths, repository
queries, directory discovery, label types and project classifiers live in
`packages/tina_app/lib/src/classification`. The generic classifier package has no
knowledge of programming languages, files, paths or a mandatory discovery phase.

## Browse saved results

`/index view` opens a full-screen directory tree in the TUI. Up/down selects a
directory; right expands it or enters its children; left collapses it or returns
to its parent. Enter opens the selected directory's details and returns to the
tree. Details include labels, explanations, evidence paths, coverage gaps,
classifier/source metadata, and checkpoint IDs. Use arrows, Page Up/Page Down,
or the mouse wheel to scroll; left/right pans long detail lines. Escape closes
the browser, and double-Esc retains its global cancellation behavior.

Each classification is marked **saved**, **incomplete**, or **missing**. Saved
means a completed checkpoint exists; it does not claim that the repository is
unchanged. `/index status` explicitly checks freshness. Partial checkpoints from
cancelled runs remain visible, and unknown labels are distinct from missing
results.

Opening the browser reads only the root and its first page of direct children
from SQLite. Expanding a directory loads its children in pages of 100; select
“load more” to fetch another page. Enter loads evidence and classifier details
for the selected node. No repository scan, Git process, file-content read, or
classifier call is part of browsing. Storage runs on a worker isolate so database
work cannot block terminal input. The reader retains a consistent snapshot while
indexing publishes newer results; close and reopen to refresh it.

`tina --prompt '/index view'` prints all saved directory summaries using the same
paged queries. No Typesafe credentials are needed. An optional `jev`/`extensions`
argument does not filter the view: it shows whichever method produced the saved
index. Existing JSON indexes are converted once on first open, with a migration
notice; that one-time conversion can take longer than subsequent opens.

## Source preparation

`RepositoryEvidenceReader` supplies bounded Git enumeration and confined file
reads. `RepositoryTextSource` selects and encodes that data as `TextEvidence`:

- `RepositoryProjection.filenames` emits only repository-relative filenames.
  File content edits do not invalidate this projection; additions/removals do.
- `RepositoryProjection.filenamesAndContents` emits filenames plus contents of
  selected manifests/configuration files. Selection names/suffixes and the raw
  input encoder are configurable and versioned independently of classifiers.

Language classification uses filenames only, including names of binary assets,
without reading their contents. Content-only edits do not invalidate language
results. Framework/tooling evidence uses a separate `RepositoryTextSource` with
`selectedOnly: true`: only selected manifests and configuration files contribute
filenames and contents. Binary asset directories therefore make no framework or
tooling model calls. Import-only usage without a selected manifest/configuration
file is not detected by this initial source; it stays unknown. Applications can
supply other sources or encoders without changing the judgment executor.

Every input unit carries a stable evidence ID, a meaning, and location metadata.
The source tracks listing and content dependencies and validates their freshness.
Complete coverage means complete coverage of the declared projection, not an
assertion that every file's contents were inspected. Skipped/unreadable selected
content is reported as incomplete coverage, never as absence.

Git enumeration includes non-ignored untracked files and excludes deleted tracked
files. Inventory is capped at 20,000 paths and 2 MiB. Collection excludes common
vendor/build directories and secret-file names. Selected content is capped at
64 files and 1 MiB total, with 128 KiB per file. File reads reject symlinks and
binary data. Existing `read`/`glob` deny rules apply during source preparation.
This implementation requires a Git repository.

## Classification and hierarchy

The source builds a directory tree from its complete Git file inventory using
`file_tree`. Each directory has a stable relative-path key. A directory's own
input contains only its direct files; child files belong to the child node.
Empty directories are not inferred from Git's file inventory.

The language classifier returns `ProjectLabels` with evidence citations.
Independent local jobs run in parallel. Starting at the leaves, `LabelMerge`
unions the supported language labels from the node's own result and its children.
The merger does not infer languages from extensions or content. Unknown results
do not establish absence, and incomplete coverage propagates to parents. No
local model call is made for a node with no direct files.

For example, adding a filename under `docs/user` invalidates that local
classification. `docs/dev`, `src` and `test` retain their results. If the output
changes, `docs/user`, `docs` and the root merge again. If the classifier returns
the same result, evidence and coverage, ancestors restore unchanged.

`extensionClassifier()` uses `LocalClassifier<TextEvidence, ProjectLabels>` and
`LocalExecutor`. It examines only the final extension of each filename, first
matching its exact case, then lowercase. For example `.C` maps to C++, `.c` to C,
and `.PY` to Python. It returns sorted, unique labels with the matching file IDs
as evidence. Unknown extensions and extensionless names stay unknown; content is
never read and there is no model fallback. The immutable rule table is part of
cache identity and can be replaced programmatically. Extension-based runs allow 20,000 classifier calls; `/index jev` allows 256.
All dimensions share a five-minute deadline. Model
spend limits do not block local language classification; framework/tooling model
requests still respect the spend ledger.

For `/index jev`, `JudgmentClassifier<I, O>` prepares typed judgment questions and decodes their
answers into a classification. `JudgmentExecutor` calls the existing
`JudgmentService` directly. Both frontends construct the configured Typesafe
service, defaulting to `jev-latest`. Saved Typesafe credentials take precedence
over `TYPESAFE_API_KEY`. Missing credentials produce an error for `/index jev`.
For the default extension method, language results are still saved, and both
framework and tooling appear as unavailable in the report. Existing framework
and tooling pointers are preserved until a configured run can validate them.
Chat models, reasoning settings, tools and agent turns are not involved, and
there is no chat fallback. The existing judgment transport, metering and pause
gate are reused.

Each request carries its input text once and asks independent yes/no (`noul`)
questions for a versioned vocabulary of programming and markup languages
(including Markdown), plus `other` and `no_language`. These are possible model
answers, not extension rules. The model may infer a language from a filename or
extension; one matching file is enough, regardless of the mix of other files.
Each language with probability greater than 0.5 becomes a label. An exact tie
stays unknown. A general `no_language` answer never vetoes a positive language
finding. With no positive findings, a complete negative requires `no_language`
at least 0.9 and every language at most 0.1; other cases stay unknown.
Citations identify the supporting input chunk, not individual file predictions.
The vocabulary, thresholds and decoder revision participate in cache identity.

Small inputs use one request. Larger inputs are packed using the complete
serialized judgment request, including state, questions and model. Source-owned
splitters handle oversized units. `ReducedClassificationPlan` merges chunk
findings in code, and `LabelMerge` does the same up the directory tree.
Neither step calls a model or averages probabilities. Unknown/incomplete
observations do not prove absence.

The Typesafe request budget defaults to 24,000 estimated input tokens, including
1,024 framing tokens. The estimate charges one token per UTF-8 byte; it is a
conservative operating bound, not an exact tokenizer. Default run limits are four
concurrent requests and five minutes, with the total classifier call limits
described above. Typesafe requests time out
after 30 seconds. Interactive runs use the shared spend ledger; standalone runs
use a 120,000-token ledger. Progress reports the configured model, input count,
estimated input tokens and elapsed request time. These diagnostics contain no raw
input text. Completed requests are checkpointed for reuse after interruption.

## Frameworks and tooling

Each directory stores three classifications: `language`, `framework`, and
`tooling`. Once the language tree completes, framework and tooling trees run in
parallel under the same session limits. Framework candidates are selected from
that directory's merged language result: Dart includes Flutter, Python includes
FastAPI/Django/Flask, and JavaScript/TypeScript includes React/Next.js/Express.
If languages are unknown, incomplete or outside the mapping, the full framework
vocabulary is considered. The detected languages do not prove framework usage.
Tooling uses a language-independent vocabulary including Docker, Kubernetes,
Terraform, GitHub Actions, build tools, package managers and test tools.

Each candidate receives an independent yes/no judgment. Probabilities do not sum
to one; all candidates above 0.5 become labels. `other` means evidence supports
something outside the candidate list. `unknown` means evidence is insufficient.
`none` requires at least 0.9 probability, complete source coverage, and all
candidates, `other`, and `unknown` at most 0.1; it becomes `notApplicable` in the
stored result. Positive labels take precedence over negative/unknown judgments.
No selected evidence produces `unknown` without a model request. A manifest-only
source does not claim to have inspected all source code.

The vocabulary, candidate selection, thresholds, source selection and language
prerequisites participate in cache identity. Each directory consumes its own
language result, so changing one subtree does not invalidate siblings. Editing a
manifest invalidates framework/tooling results while filename-based languages
restore unchanged. Chunking and tree merging reuse `ReducedClassificationPlan`
and `LabelMerge`; neither merge step calls a model.

## Persistence

`.tina/classifications/index.db` is the authoritative SQLite store. It replaces
the JSON manifest and record directory; there is no duplicate display snapshot.
SQLite maintains its normal WAL and shared-memory sidecars while connections are
open. The directory remains self-ignored.

Records keep their content-addressed IDs. `refs` holds the current task/request
references, `nodes` indexes parent/child relationships, and `labels` holds each
project label and its evidence once. Other typed output stays in the record's
value field. Large provenance and evidence fields are fetched only for details.
The browser's small summary queries use indexed node/reference lookups.

Each completed request or merge publishes its record and reference in one short
transaction. A writer lock covers an indexing run; WAL readers can browse the
previous committed state concurrently. Cancellation preserves committed progress.
The generic classifier uses `CheckpointStore` for atomic publication without
rewriting a full manifest on every result. It has no SQLite dependency.

Migration imports and validates the legacy records and their references in a
transaction, retaining record IDs and request links. After commit, it removes the
imported JSON files and manifest. An interrupted cleanup resumes on next open;
a failed import leaves the legacy files intact. No classifier rerun is needed.

A final record stores typed output, coverage, versioned provenance and an opaque
source receipt. Raw evidence text, credentials and raw model responses are not
stored. The service endpoint and configured model remain in cache provenance.

Restoration checks source freshness, contract/encoder/splitter/plan/agent/model
identities, budget configuration and consumed results. Local and aggregate results are
separate: `docs/user::language::local` and `docs/user::language`, with matching
`::framework` and `::tooling` keys in the same database. Parent receipts
persist child keys and hashes of result/evidence/coverage, excluding storage IDs.
Relevant changes invalidate dependent work; independent branches remain reusable.
Method selection is explicit and included in cache identity. Switching methods
updates the active tree pointers, without interpreting one method's answers as
the other's. Immutable request checkpoints for both methods remain reusable.
Interrupted chunked work resumes from matching request checkpoints. Locals check source freshness before publication; the completed tree checks
membership and all local receipts again before returning current aggregates.
Incomplete discovery does not delete previously known nodes. Successful runs
retire pointers for deleted nodes across all three classifications. Old immutable records are retained; GC is
deferred. Old v1 records are cache misses under the new v2 schema.

The old environment workflow, startup setup prompt, `ENVIRONMENT.md` injection
and `/index` environment gating remain removed. Existing files are left unused;
legacy `[environment]` configuration values are preserved on save but ignored.
Experts and setup/build/test execution are outside this feature.
