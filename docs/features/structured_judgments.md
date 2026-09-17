# Structured judgments with TypeSafe

Backend implementation, 2026-09-17. Public entry point:
`package:tina_engine/judgments.dart` (also exported by `tina_engine.dart`).

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

## Locate an implementation

After setting the key, run this in a Git project:

```text
/explore where is tool cancellation handled?
/explore where is RuntimeProviderFactory implemented?
```

The conversation's chat model asks the `explore_project` tool and explains its
structured findings. During this turn, direct file tools, shell tools, generic
delegation, and arbitrary workflows are unavailable. Other conversation turns
retain their normal tools. Tool execution uses the existing approval policy:
ask/auto may prompt, read-all/allow-edits permit this read-only tool, and explicit
deny rules still win. The tool description makes clear that selected excerpts
are sent to Typesafe. Normal TUI and headless agents can also call the tool
explicitly; the slash entry point is interactive.

Progress appears in the tool output and `/output`. Normal turn cancellation
stops collection and judgments. The request and result use ordinary conversation
persistence. This is an awaited collection → judgment → findings workflow,
not a detached DOT run or a separate scout chat session.

Tina enumerates tracked and unignored working-tree files with a fixed, read-only
Git command (optional locks and fsmonitor disabled). It searches filenames and
source lines locally, then asks parallel **Score** judgments to rate relevance
against the same five-level rubric. Typesafe never chooses filesystem paths,
runs commands, or writes summaries. Findings copy paths, line numbers, and text
from collected evidence; the model supplies only relevance and confidence.

The first version uses these fixed limits:

| Resource | Limit |
| --- | --- |
| Enumeration | 5,000 paths / 4 MiB / 10 seconds |
| Source scan | 8 MiB total, 128 KiB per file |
| Shortlist | 24 excerpts, up to two per file, 4,000 characters per excerpt |
| Judgment dispatch | Four concurrent requests, at most 48 requests |
| Admission budget | 120,000 charged tokens; 1,024 output tokens reserved per request |
| Deadlines | 30 seconds per request; two minutes for the workflow |
| Returned findings | Top eight with relevance at least 0.5 |

Hidden paths, common dependency/build directories, symlinks, binaries, common
credential filenames, and unsupported extensions are skipped. These filename
filters are not a secret detector. Changed/unreadable/oversized files are skipped
and summarized in coverage gaps. A lexical shortlist can miss implementations
without shared words: a result is always non-exhaustive, and empty findings never
mean the implementation does not exist. Narrow the question using likely symbols
or feature names. Non-Git folders are not supported in this first version.

Results include `status`, `findings` (path, start/end line, excerpt, relevance,
confidence), `coverage` (files scanned, chunks judged, gaps), and separate Typesafe
usage. Failed requests preserve successful findings and keep unknown usage null.
The batch admission charge is not actual billing and is separate from chat spend.

The evidence source, judgment service, and invocation factory are injectable.
Tests cover a real temporary Git repository (ignores, symlinks, bounded reads,
fresh edits), fake typed judgments, tool progress/cancellation, restricted turns,
command dispatch, and key rotation through a mocked HTTP endpoint. No real API
key or remote model is needed for these tests.

## Backend usage

This function can be called by application composition with an explicitly
resolved credential. It returns data to its caller; it does not spawn a worker.

```dart
import 'package:tina_engine/judgments.dart';

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
for each invocation; persistent indexing and caching remain future work.

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
environment transitions, and arbitrary workflow launching are excluded.
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
plus the output allowance synchronously before each call. Reservations are not
refunded on failure or missing usage. Reported usage above a reservation raises
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
questions, record expected paths, compare top-eight recall, wall time, actual
usage when provided, and failures. Fixture tests validate plumbing and boundaries;
they do not establish live model accuracy, pricing, or a speedup.
