# Structured judgments with TypeSafe

Backend implementation, 2026-09-17. Public entry point:
`package:classifier/judgments.dart` (the HTTP service lives in
`package:classifier/typesafe_classifier.dart`).

## How it fits

TypeSafe accepts a state snapshot and questions, and returns constrained
judgments. It does not accept Tina's chat history/tool protocol, generate
patches, or run agents. The integration implements `JudgmentService`, separately
from `LlmProvider` and `ProviderRegistry`. Its credentials, endpoint and model
belong to `TypeSafeConfig`; chat defaults, output limits, reasoning settings,
retry ladders and provider pools do not apply.

The API supports three answer forms: Choice (selected option, probabilities,
confidence), Score (fractional position, legend, probabilities, confidence),
and Noul (probability of yes). These are constrained judgments, not arbitrary
JSON-schema generation. See the official [primitives](https://docs.typesafe.ai/primitives)
and [HTTP reference](https://docs.typesafe.ai/api).

A future swarm controller can inject this service to judge readiness, choose
among available worker IDs, or assess results. It supplies state and allowable
options, then makes scheduling and execution decisions in ordinary code. It
must define its own action thresholds and budgets. Questions sharing state go
in one batch; a dependent judgment gets a later state snapshot and request.
The first concrete workflow is implementation exploration, described below.
Credentials can be configured through the settings UI.

## Configure the API key

Open `/settings`, select **Typesafe**, paste the key, and press Enter to save.
The field is masked. Typing or pasting replaces an existing key; Backspace
edits it, Delete clears the saved key, and Esc/Ctrl+C cancels without saving.
Saving uses the existing private config-file writer (0600 on supported systems).
It stores the credential locally; it does not make a billable authentication
probe or claim the key has been verified by TypeSafe.

```toml
[typesafe]
api_key = "your-key"
# model = "jev-latest"
```

The saved key takes precedence over `TYPESAFE_API_KEY`. Clearing it restores
the environment fallback if one is set. It never creates a chat provider or
changes the active conversation's model. Other settings preserve this section.

Application composition can call `createConfiguredTypeSafeService` from
`lib/composition/typesafe.dart`, supplying the launch environment. It reads the
latest config on each construction and returns null when no key is available.
Existing service instances retain their configuration. The exploration tool
creates and closes one service per invocation, so saved credential changes apply
to the next invocation without restarting.

## Filter the repository for the main agent

After setting the key, run this in a Git project:

```text
/explore does this file handle tool cancellation?
/explore does this file implement provider authentication?
```

The main conversation calls `explore_project`. The objective is to deliver useful
source evidence quickly, rather than judge every file or explain the architecture
inside a separate scout. Direct filesystem, shell, generic delegation and other
workflow tools remain unavailable during the slash-command turn. The filter
returns actual source text so the main agent can do the reasoning itself.

The filter has two stages:

1. **Rank a compact file manifest.** Enumerate eligible paths without reading
   bodies. Group filenames under directory prefixes, assign stable IDs, and ask
   one independent Noul question per file: is it worth reading for this goal?
   Use one request if the complete JSON fits. Otherwise pack bounded pages and
   evaluate them concurrently. A deeply nested file appears directly in the
   manifest; no directory-by-directory judgments gate access to it.
2. **Read and check selectively.** Start with the highest-ranked files, in waves
   bounded by request concurrency. Ask whether each source region contains
   useful evidence. Stop once the requested number of useful files is found
   (one by default; an already-running wave can finish). If inconclusive, expand
   to the next candidates, including low filename scores. Scores never prove
   that unexamined files are irrelevant.

Tool inputs support three modes, without changing the advertised tool schema
between calls:

```json
{"question":"Where is tool cancellation handled?","mode":"auto","max_results":1}
```

- `auto` (default): skip Typesafe content verification when a small, clear set of
  candidates can be handed to the main agent as complete source files. Scores
  must meet `exploration_selection_threshold` (default 0.9), with at least a 0.2
  gap to the next candidate. There must be at most three candidates and no more
  than `max_results`, each at most 6,000 Unicode scalars and 12,000 total.
  Their excerpts are explicitly labeled unverified; the main agent analyzes them.
- `verify`: always perform content judgments, even for obvious filenames.
- `rank`: return candidate paths only; do not read or send any file bodies.

`max_results` accepts 1–8. Filename scores are inspection priorities. Content
scores apply only to the regions sent, not the entire file or repository. The
main agent cites and explains supplied source excerpts; it must not invent
unseen function bodies or assume that a low score proves absence.

### Large files and evidence handoff

A complete file that fits uses one content request. Larger files automatically
split into two requests when sufficient, or more when needed. The chunker prefers
blank-line/newline boundaries, overlaps up to three lines (bounded relative to
chunk size), and splits very long lines at Unicode scalar boundaries with a
small overlap. This is language-independent line chunking, not an AST parser.
Every request is checked including its question and metadata. Source is not
silently dropped; context too small even for the rubric or the 256-chunk file
limit is reported explicitly.

File regions run concurrently within the configured limit. A match can stop
later regions; counts identify how much of each file was actually checked.
Probabilities are not averaged or combined into a whole-file confidence.

The handoff includes stable local paths, region line ranges and source excerpts.
A useful file contributes one matching excerpt, capped at 24,000 Unicode scalars;
truncation is explicit (the default request budget usually bounds it below that).
At most eight candidate names, twelve file results, and eight region results per
file are serialized. Evidence comes first. Omission counts distinguish compact
reporting from unexamined files; all ranking decisions remain available inside
the running filter. This avoids sending hundreds of low-value scores to the
main agent.

### Limits, cancellation and metrics

| Resource | Default limit |
| --- | --- |
| Enumeration | 5,000 paths / 4 MiB / 10 seconds |
| Reads | 8 MiB across the run, 1 MiB per file |
| Dispatch | Four concurrent requests, 5,000 requests per stage |
| Manifest admission budget | 60,000 charged tokens |
| Content admission budget | Separate 120,000 charged tokens |
| Request context | Complete JSON checked by `JudgmentRequestBudget` |
| Output reservation | 1,024 tokens per request |
| Deadline | 30 seconds per request; 120 seconds for the whole run |

These settings reload for the next invocation without restarting:

```toml
[typesafe]
# Preserve existing api_key/model entries.
exploration_metadata_token_budget = 60000
exploration_token_budget = 120000
exploration_selection_threshold = 0.9 # auto handoff only; not a pruning cutoff
exploration_timeout_seconds = 120
```

Progress and results use the normal conversation lifecycle. Cancellation closes
active Typesafe requests and stops queued work and reads. Git enumeration uses
fixed read-only arguments with optional locks and fsmonitor disabled. Git ignore
rules, hidden/build/dependency paths, unsupported extensions, known credential
filenames, binaries and symlinks remain excluded. Filters are not a secret
detector. Non-Git folders fail explicitly. Deleted, changed, oversized and
inaccessible files remain coverage gaps.

The result reports `stop_reason`, ranking coverage, per-file checked/total chunks,
source evidence and deferred/omitted counts. `completed` means the filter finished
its task, not that every file was examined. Failures remain distinct from negative
scores. No result claims exhaustive repository coverage.

Usage separates metadata/content requests and charged tokens from measured input
and output tokens. Complete reported usage replaces a reservation; failures or
incomplete usage retain their conservative reservation. The run also reports
`elapsed_ms` and `first_evidence_ms` (when the workflow assembled its first source
handoff, not when the provider started responding). The final tool result is the
handoff to the main agent.

Tests cover compact manifests containing deep packages, concurrent pagination,
early stopping and fallback to lower-ranked files, optional verification,
context splitting, Unicode/line coverage, cumulative read/dispatch budgets,
cancellation, Git exclusions and source freshness. A controlled 80-file fixture
asserts that a successful first wave reads/checks only two files with concurrency
two. This verifies dispatch behavior, not real-world search quality or speed.
Before claiming improvement over grep/read, compare representative questions
against known relevant locations and record recall, end-to-end handoff latency,
Typesafe usage plus main-agent input, and the direct-exploration baseline.

### Local reuse

Exploration caches structured evidence in `.tina/exploration/` as versioned JSON
records. Atomic replacement makes records safe to read across processes and
restarts. The cache creates its own ignore rule; it does not require the project
to already ignore `.tina/`. Unavailable, read-only or corrupt storage is treated
as a cache miss, never as an exploration failure. Each record read is bounded
at 8 MiB. No API credentials or main-agent conversation history are stored.

There are two levels:

- **Individual judgments:** keys hash the endpoint and exact serialized API
  request (including model, question/instructions, paths and supplied content),
  with an entry-type discriminator. There is no additional cache revision,
  repository hash or whole-file hash: an identical listing page or source region
  remains reusable when other pages or regions change. Successful negative
  judgments are cached too; failed attempts are not.
- **Completed exploration answers:** records retain the full structured result,
  original usage and coverage, manifest fingerprint, question/result settings, and
  hashes of **every examined file**, including negatives and files omitted from
  the compact handoff. Before replay, Tina enumerates paths again and re-reads
  those dependencies through the normal bounded source adapter. A same-length
  edit is a change even if timestamps or Git HEAD do not change.

Additions, deletions, renames or eligible-list changes invalidate the whole answer.
Ranking requests whose serialized inputs change are evaluated again; identical
requests remain reusable. A content-only edit invalidates the answer and changed
region requests, while preserving ranking and identical region requests.
Question changes are exact matches (apart from tool-input trimming), not semantic
similarity matches. Endpoint, ranking/content models, mode, result count,
thresholds and algorithm revision must match for whole-answer replay. Execution
settings (budgets, concurrency, context/read limits and timeouts) are not cache
keys; current read limits still apply when validating the saved evidence.
Completed judgments from interrupted or limited runs can
be reused to continue work, but those runs are not saved as completed answers.

Records have **no time-based expiry**: matching requests, directory listings and
examined file contents remain reusable regardless of age. This also applies to
model aliases such as `jev-latest`; use `refresh` to request a fresh judgment.
Prompt/algorithm or snapshot-codec changes require incrementing
`explorationCacheRevision` for assembled answers. Individual judgments depend
only on the endpoint and actual request, so changed prompts invalidate them
automatically without discarding unrelated judgments.

To bypass reuse for an invocation, the agent supplies:

```json
{"question":"Where is tool cancellation handled?","mode":"verify","refresh":true}
```

Fresh successful results then populate the cache. Hits are resolved before API
admission accounting, so they use **zero new requests and zero new tokens**, even
when the new API budget is small. The result's `cache` field distinguishes an
answer hit from metadata/content judgment hits; original usage stays in stored
records rather than being billed again. Local enumeration and hashing still
happen. Reuse retains the original coverage limits: unexamined file contents
remain unknown. The cache directory is disposable.

Storage is injected through `ExplorationCache`. The workflow, ranker and cache
policy have no filesystem dependency; `FileExplorationCache` owns disk access.
Tests cover restart persistence, negative-evidence invalidation, same-length edits,
manifest additions/deletions/renames, partial failures, budget-free hits, refresh,
reuse regardless of age or execution settings, unchanged chunks/listing pages,
model changes, cancellation, corrupt storage, atomic writes and Git exclusion.

## Backend usage

This function can be called by application composition with an explicitly
resolved credential. It returns data to its caller; it does not spawn a worker.

```dart
import 'package:classifier/typesafe_classifier.dart';

Future<({String worker, double confidence, double blockedProbability})>
    assessTask(String apiKey, Map<String, Object?> task) async {
  final service = TypeSafeJudgmentService(
    config: TypeSafeConfig(apiKey: apiKey), // model defaults to jev-latest
  );
  final route = ChoiceQuestion('worker',
    instructions: 'Which available worker best matches `task`?',
    criteria: {
      'implementation': 'Changes application code',
      'validation': 'Runs and reviews tests',
      'none': 'No listed worker fits',
    },
  );
  final blocked = NoulQuestion('blocked',
    instructions: 'Does `task` lack information required to begin?',
  );
  try {
    final result = await service.evaluate(JudgmentRequest(
      state: {'task': task},
      questions: [route, blocked],
    ));
    final ChoiceAnswer choice = result.answer(route);
    final NoulAnswer readiness = result.answer(blocked);
    return (worker: choice.choice, confidence: choice.confidence,
      blockedProbability: readiness.noul);
  } finally {
    service.close();
  }
}
```

Keep a service at application scope for normal use and close it on shutdown.
`model` may be pinned in `TypeSafeConfig`; returned `result.model` records the
server's model identifier, which may resolve an alias to a version. There is
no connection to the active conversation's model selection.

`ScoreQuestion` accepts 2–10 ordered levels. `ScoreAnswer.score` spans zero to
the last index and `normalized` scales it to 0–1. Level maps use integer keys
in Dart. Choice supports 1–255 named options. Noul deliberately supplies no
invented confidence or boolean conversion. Confidence is a model signal, not
a guarantee of correctness.

State is a JSON string/object/array. Instructions and rubric descriptions also
support structured content and null where documented in the
[advanced reference](https://docs.typesafe.ai/primitives/advanced); they are not
stringified prompts. All input collections are recursively snapshotted and
frozen. Unsupported objects, cycles, non-finite numbers, and excessive nesting
are rejected before HTTP. Calling `result.answer(question)` preserves the
question's answer type and rejects a different question object reusing its ID.

## Reliability and ownership

- One `POST /v1/systemone` with Bearer authentication per evaluation. There are
  no hidden retries. `JudgmentException` provides a failure category, optional
  HTTP status and Retry-After delay, and `isRetryable` for caller policy. Any
  retry must use a bounded backoff/budget; cancellation must also cover waits.
- A 30-second configurable deadline covers headers and the entire response.
  Each evaluation owns a fresh HTTP client so cancellation cannot terminate
  sibling requests. This favors isolation over connection pooling; inject a
  fresh-client factory for transport tests, never a shared client that another
  request still owns. Do not wrap it in an independently retrying client.
- A `JudgmentCancellation` can cancel one call or a group. `service.close()`
  cancels active calls and rejects new ones; callers await their evaluation
  futures to observe settlement. Successful calls detach cancellation listeners.
- Responses are bounded to 8 MiB by default, including chunked bodies. Redirects
  are refused. Credentials require HTTPS except for explicit loopback test URLs.
  Request state, credentials, and raw error bodies are never logged or included
  in service exceptions.
- A batch is returned only after every requested answer is present with the
  correct type, option/level keys, finite in-range numbers, and matching score
  legend. Unknown metadata is tolerated. Probability totals allow 0.01 absolute
  rounding tolerance; malformed distributions are not silently normalized.
- Usage remains separate from chat metering. Actual reported token counters
  are retained; absent counters remain null. No cost or failed-attempt token
  usage is invented. Batch admission uses separate conservative accounting,
  described below; it does not report its reservations as measured spend.

## Scout foundations

The exploration workflow uses these building blocks. It collects fresh evidence
for each invocation; exploration now reuses validated local cache entries as described above.

### Request budgeting and evidence chunks

`TypeSafeConfig.requestBudget` checks every request before constructing a client.
`JudgmentRequestBudget` counts the complete serialized payload (model, state,
questions, instructions, and criteria), plus an overhead allowance. Its default
operating target is 24,000 tokens including 1,024 tokens of overhead. This leaves
headroom below the [documented approximate 32k shared window](https://docs.typesafe.ai/primitives).
It is not a provider-advertised exact limit. Pin the model and supply its budget
explicitly when those assumptions change.

The fallback charges one token per UTF-8 byte, intentionally conservative for
source code and multilingual evidence. A verified tokenizer can be injected as
a conservative, monotonic `JudgmentTokenEstimator`. The character approximation
from the documentation is not used as an exact tokenizer. Oversized requests
fail locally with `JudgmentFailure.requestTooLarge`.

The general-purpose `budget.chunkText` utility is available to other consumers;
exploration uses its own overlapping `FileChunker` so it can preserve line ranges.
`budget.chunkText(source: path, text: evidence, questions: questions)` creates
bounded requests with source and Unicode scalar offsets. It prefers newline
boundaries and continues oversized lines without cutting Unicode characters.
Concatenating chunk text reproduces the input exactly. The caller can supply
individual symbol/function bodies to preserve semantic boundaries. Questions
and choice criteria stay intact in each chunk. Oversized metadata/rubrics and
exceeding `maxChunks` fail explicitly; nothing is silently discarded. The
caller must treat each answer as local to its chunk. Do not compare or merge
choice probabilities across different candidate sets; re-evaluate finalists
together. There is no automatic retry for a provider's generic HTTP 422.

### Filesystem-free orchestrator

App composition now accepts
`buildAgent(..., toolAccess: AgentToolAccess.orchestrator)` independently of
permission mode and `withSubAgents`. It advertises the concrete `ask_user`
and, when supplied, `explore_project` tools and installs a deny-by-default execution guard. File tools, shell tools,
plugin aliases, general delegation, channel messaging, region/summary access,
arbitrary workflow launching are excluded.
Changing approval mode or replacing the per-turn registry does not grant those
capabilities. Restrictions stay on this driver, not sibling conversations.

Pass `exploreProject: tool` to supply the bounded exploration tool. Normal
agents keep the standard profile; `/explore` selects this restricted catalog for
one turn through the existing turn executor. This is a tool-capability boundary,
not an OS sandbox for arbitrary trusted plugin/driver code.

### Bounded judgment execution

Use one `JudgmentBatchRunner` per workflow with the configured service and the
same request budget as `service.config.requestBudget`. Supply
`JudgmentBatchLimits(maxChargedTokens: ..., outputTokenAllowance: ...)`.
Defaults are four concurrent calls, at most 256 requests, a 30-second per-call
deadline, and a two-minute batch deadline. Overlapping runs on a runner fail;
separate runners have independent budgets and concurrency limits.

The runner validates all requests before dispatch and reserves estimated input
plus the output allowance synchronously before each call. Complete reported input and output usage replaces the reservation. Queued work
waits for in-flight reservations to settle before a budget refusal, preserving
request priority. Reservations are not refunded on failure or incomplete usage.
Reported usage above a reservation raises
the charge; if this crosses the batch limit, active work is cancelled and queued
work is skipped. Results retain input order, successful evidence, typed failures,
and whether each request was attempted. There are no retries.

`chargedTokens` bounds admission conservatively; it is not measured usage or a
guaranteed monetary ceiling. The API has no output-budget field here, so a call
can exceed its allowance before usage is reported. Callers must choose adequate
allowances. Existing in-flight calls may also incur usage before cancellation.
Unknown actual counters remain unknown in each result.

Caller cancellation and deadlines propagate to active HTTP clients and stop
queued work. Injected services must honor `JudgmentCancellation`; the runner can
settle a stalled future, but cannot forcibly stop arbitrary adapter code. The
runner does not own or close the shared service; its application owner does.

## Testing and next integration

`test/judgments/` covers mixed batches, typed lookup, immutable inputs,
structured/null rubrics, malformed replies, HTTP errors, deadlines, cancellation,
sibling isolation, response limits, redaction, and a local HTTP redirect test.
The model and service contracts have a transitive no-I/O architecture guard.
Consumers can implement `JudgmentService` with fixture results constructed by
`JudgmentResult.fromJson(..., request: request)`; no model, UI, or live credential
is needed for orchestration tests.

No authenticated TypeSafe request has been run for this implementation. Wire
behavior is tested against the published shapes with fake/local transports.
Next, measure live relevance and performance against the existing scout flow
before expanding into persistent indexing. Use the same repository revision and
questions, record expected paths, compare per-file precision/recall, wall time, actual
usage when provided, and failures. Fixture tests validate plumbing and boundaries;
they do not establish live model accuracy, pricing, or a speedup.

## Session review: `/classifier-review`

`/classifier-review [focus]` reviews the active conversation for judgment
questions worth adding. It sends one fresh-context request — a dedicated
system prompt, the conversation's provider, no tools — with the history
passed as data, then streams the markdown reply into the transcript. The
history and the session recorder are untouched: a review is advice, not a
turn, so it never enters the conversation context or `/save`'s export.

The prompt pins the question shapes (choice 1–255 options, score 2–10
levels, noul; flat_snake ids; JSON-only state within the ~24k request
budget) and the discriminator: a deterministic rule or an existing mechanism
is not a candidate — TypeSafe is for decisions that must be judged. Every
candidate must cite the session exchange that justifies it, name the state
fields available at the decision moment, and name the caller that would act
on the answer; an empty result stated plainly is a valid outcome. The
transcript is declared data, so instructions embedded in tool output are
reviewed, not obeyed.

The final message carries session context the transcript lacks: model,
permission mode, configured rules, and remembered approvals — counts exact,
listings capped at 60 lines each. Approval decisions are sink output, never
history messages, so the grants list is the only record of what was prompted
and who answered. An optional `focus` argument (≤2000 characters) narrows
the review, e.g. `/classifier-review commit messages`.

The request is pre-flighted against the conversation's token budget
(`--max-request-tokens`) and cancels on ESC like any command; spend is
booked by the metered provider stack. The command runs headless and needs no
TypeSafe key — it uses the chat provider to *propose* questions, not the
TypeSafe API to answer them.

After a successful review, the command appends an adoptable **classifier
program fragment**: the built-in `/index` program rendered as DOT, with
reader instructions and the review's focus as `//` comments. Save it as
`<repo>/.tina/programs/index.dot` (or `~/.tina/workflows/index.dot` as a
global default) to adopt it, then `/workflow edit index` opens it in the
visual editor — workspace programs resolve first and save back to their
origin, and `graphToDot` rewrites are canonical, so load → edit → save
round-trips without loss. See [the classifier programs
section](INDEX_COMMAND.md#classifier-programs) for resolution precedence
and routing rules.
