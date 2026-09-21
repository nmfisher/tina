# Project classification

`/index` classifies programming and markup languages, from the leaves of the directory
tree back to the root. `/index status` validates/restores saved results without
model calls or writes. `/index refresh` reruns classification. The same commands
work with `tina --prompt`; incomplete headless runs exit nonzero. TUI double-Esc
and headless Ctrl+C cancel. Nothing runs on startup. Indexing does not launch
summary agents, region-layout proposals, setup, or other project classifiers.
The default is local extension matching. `/index jev` selects the model-based
implementation; both methods accept `status` and `refresh`.

The reusable API is documented in [classifier](../../packages/classifier/README.md).
The project feature is an application recipe built on that API. Paths, repository
queries, directory discovery, label types and the language classifier live in
`packages/tina_app/lib/src/classification`. The generic classifier package has no
knowledge of programming languages, files, paths or a mandatory discovery phase.

## Source preparation

`RepositoryEvidenceReader` supplies bounded Git enumeration and confined file
reads. `RepositoryTextSource` selects and encodes that data as `TextEvidence`:

- `RepositoryProjection.filenames` emits only repository-relative filenames.
  File content edits do not invalidate this projection; additions/removals do.
- `RepositoryProjection.filenamesAndContents` emits filenames plus contents of
  selected manifests/configuration files. Selection names/suffixes and the raw
  input encoder are configurable and versioned independently of classifiers.

`runProjectClassification` accepts the projection programmatically; the command
uses filenames only, including names of binary assets, without reading their
contents. Content-only edits do not invalidate this projection. An application
can supply another source or encoder without changing the judgment executor.

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
Independent local jobs run in parallel. Starting at the leaves, `LanguageMerge`
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
cache identity and can be replaced programmatically. Local runs have a 20,000-call
limit and share the same five-minute deadline and cancellation as model runs.
Model spend limits do not block local classification.

For `/index jev`, `JudgmentClassifier<I, O>` prepares typed judgment questions and decodes their
answers into a classification. `JudgmentExecutor` calls the existing
`JudgmentService` directly. Both frontends construct the configured Typesafe
service, defaulting to `jev-latest`. Saved Typesafe credentials take precedence
over `TYPESAFE_API_KEY`; missing credentials produce a configuration error.
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
findings in code, and `LanguageMerge` does the same up the directory tree.
Neither step calls a model or averages probabilities. Unknown/incomplete
observations do not prove absence.

The Typesafe request budget defaults to 24,000 estimated input tokens, including
1,024 framing tokens. The estimate charges one token per UTF-8 byte; it is a
conservative operating bound, not an exact tokenizer. Default run limits are four
concurrent requests, 256 requests and five minutes. Typesafe requests time out
after 30 seconds. Interactive runs use the shared spend ledger; standalone runs
use a 120,000-token ledger. Progress reports the configured model, input count,
estimated input tokens and elapsed request time. These diagnostics contain no raw
input text. Completed requests are checkpointed for reuse after interruption.

## Persistence

`.tina/classifications/manifest.json` references immutable `records/<sha256>.json`
files. The directory is self-ignored and writer-locked. Each completed request,
including each input chunk, is checkpointed. Code merges have their own final
records but make no requests. A final
record references those request records and stores typed output, coverage,
versioned provenance and an opaque source freshness receipt. Raw evidence text,
credentials and raw model responses are not stored. The service endpoint and
configured model are included in cache provenance.

Restoration checks source freshness, contract/encoder/splitter/plan/agent/model
identities, budget configuration and consumed results. Local and aggregate results are
separate: `docs/user::language::local` and `docs/user::language`. Parent receipts
persist child keys and hashes of result/evidence/coverage, excluding storage IDs.
Relevant changes invalidate dependent work; independent branches remain reusable.
Method selection is explicit and included in cache identity. Switching methods
updates the active tree pointers, without interpreting one method's answers as
the other's. Immutable request checkpoints for both methods remain reusable.
Interrupted chunked work resumes from matching request checkpoints. Locals check source freshness before publication; the completed tree checks
membership and all local receipts again before returning current aggregates.
Incomplete discovery does not delete previously known nodes. Successful runs
retire pointers for deleted nodes and the removed non-language tasks. Old immutable records are retained; GC is
deferred. Old v1 records are cache misses under the new v2 schema.

The old environment workflow, startup setup prompt, `ENVIRONMENT.md` injection
and `/index` environment gating remain removed. Existing files are left unused;
legacy `[environment]` configuration values are preserved on save but ignored.
Experts and setup/build/test execution are outside this feature.
