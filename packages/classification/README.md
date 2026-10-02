# Input classification

`tina/classification` classifies the latest user input in the background:
project question, agent instruction, a learned category, Other, or unclear. Only detected
instructions proceed to Git classification: no Git request, unclear, or one or
more subcommands (push, branch, checkout, commit, etc.).

The plugin is informational: it never executes commands, changes permissions,
rewrites input, or adds its predictions to the conversation. The status bar and
`/classification` show the latest result. Each session owns its latest result; new
input supersedes pending work. Cancellation, timeout and unload close the service
and prevent late results from changing the display. The last result is transient
and is not restored from session storage.

The app enables it by default; explicit enabled-plugin lists need
`tina/classification` added. Its checkbox in Settings → Plugins enables or
disables it live. The Typesafe transport reads `[typesafe].api_key`, `model` and optional
`endpoint` from the global config for each input. A stored key wins over
`TYPESAFE_API_KEY`; a stored `${VARIABLE}` resolves from the environment. Missing
credentials show unavailable, without making a network request. Chat generation
continues independently. Classifier calls use their own bounded request budget.
The configured plugin allows 90 seconds for classification and discovery together;
each discovery has a 60-second timeout. Typesafe usage stays separate from the
conversation provider's usage; discovery requests obey and charge normal provider policy.

## Learning categories and questions

The intent vocabulary starts with **project question** and **instruction**, plus
**Other**. Selecting Other at the confidence threshold asks the active main model
to propose the best reusable category in a fresh context. That request includes
only the submitted input, the classification question and existing definitions.
It has no conversation history or tools and uses its own provider client.

Each category has a stable ID, label, description and a reusable membership
question. The classifier sees these learned questions on later inputs. Existing
categories can be reused; normalized duplicate labels are coalesced, and a
conflicting ID cannot overwrite a definition. After learning, the current input
is classified once more against the expanded vocabulary. There is at most one
discovery/reclassification per question per input, so repeated Other decisions
cannot create a loop. Git operation questions learn unlisted subcommands in the
same way, while retaining multiple requested operations.

Each question permits **254 named categories plus Other**. At capacity Other
remains usable, but new discovery stops. Failed, malformed, incomplete or
cancelled discovery cannot introduce a definition. Low-confidence and unclear
decisions do not train the vocabulary. Request budgeting includes every category;
an oversized vocabulary/input is reported instead of silently dropping choices.

The vocabulary and selection counts are global, shared across workspaces and
sessions, in `~/.tina/classification/categories.json`. With `--config FILE`, the
catalog is `classification/categories.json` alongside that global config file.
The plugin owns storage; atomic replacement, a process lock and an in-process
queue protect simultaneous sessions. A corrupt catalog is reported and preserved,
never silently reset. Its schema stores definitions and counters, with no input
or conversation-history fields. Definitions and counters survive session close,
restart and plugin reload.

Every successful classifier selection increments its category's `selections`
counter. Other has its own counter. Reclassification is another selection;
proposing/admitting a category alone does not count as selecting it. Unselected
categories start at zero. `/classification categories` lists definitions, their
questions and counts. No pruning is implemented yet.

Package API:

- `utterance.dart`: adaptive classification, category definitions, storage and
  learner interfaces, plus original intent/Git judgments for legacy callers.
- `category_store.dart`: the plugin's atomic filesystem catalog adapter.
- `plugin.dart`: the terminal-independent engine2 plugin, result/status stream,
  and owned classifier service lease.
- `config.dart`: the existing Typesafe config reader.
- `typesafe_classifier.dart`: the existing HTTP transport.
- `classification.dart`, `judgments.dart`, `exploration.dart`: retained library
  APIs for legacy callers. Repository indexing/exploration is not activated.

The thin status renderer is in the existing `tina_chat_tui` package; it adapts the
same plugin ID and keeps terminal imports out of classification. Legacy
`tina_app` intent/Git exports delegate here, with only a message-type adapter.

# Structured judgments and repository classification

The package provides structured judgments, exploration, and a domain-independent
classification API. Import `package:classification/classification.dart` for the typed
source and classification pipeline. It has no filesystem, engine, or UI dependency.

A classification task binds these contracts:

- `ClassificationSource<I>` prepares a bounded snapshot of input units and owns
  freshness validation. `SourceRequest.subject` is an opaque ID, not a path.
- `InputEncoder<Raw, I>` is an optional source-side formatter/visitor. Sources
  using the same input contract can use different raw data and encodings.
- `DataContract<T>` defines a stable ID, revision, JSON schema and codec. Those
  identities, not Dart runtime type names, are used in persistence.
- `ClassifierDefinition<I, O>` pairs typed inputs and outputs with an agent type,
  instructions, versions, and optional domain validation.
- `JudgmentClassifier<I, O>` adds typed judgment preparation and decoding, with a
  versioned `spec` for question vocabulary and decision policy.
- `LocalClassifier<I, O>` supplies a deterministic function and versioned rule
  `spec`. `LocalExecutor` runs it without model tokens or network access, using
  the same typed validation, scheduling and cache machinery.
- `ClassificationExecutor` binds requests to model execution and estimates the
  complete serialized request. `JudgmentExecutor` uses a `JudgmentService`
  directly, with its existing transport, cancellation and request budget.
- `ClassificationPlan<I, O>` defines single-request or bounded map/reduce execution.
- `ClassificationOrchestrator` owns cancellation, call limits, global concurrency,
  dependency scheduling, durable checkpoints and restoration through an injected
  `ClassificationStore`.

For example, a filename source and a document-content source can both produce
`TextEvidence`, while a classifier accepts `TextEvidence` and returns a typed
category set. An unrelated application can accept numeric records and return a
score. Text is one available contract, not a required universal string wrapper.
`TextEvidence.meaning` describes whether its text is a name, content, excerpt,
summary, etc.; source locations and evidence IDs accompany the value.

```dart
final task = ClassificationTask<TextEvidence, CategorySet>(
  key: 'catalog:item-42',
  request: SourceRequest('item-42'),
  source: catalogSource,
  plan: SingleRequestPlan(categoryClassifier),
);
final record = await ClassificationOrchestrator(
  store: store,
  executor: executor,
).run((session) => session.classify(task));
```

`catalogSource`, `categoryClassifier`, `store`, and `executor` above are
application-owned implementations. Repository-specific adapters and the project
classification recipe live in `tina_app`, not this API.

## Context and reduction

A source provides immutable units, coverage, an opaque revision receipt, and an
optional splitting policy. Whole units are packed first. Only an oversized unit
is split, at boundaries chosen by the source. The shared text splitter prefers
newlines and falls back to Unicode scalar boundaries, preserving offsets and all
content. Structured sources may be atomic or provide a different splitter.

`ClassificationBudget` reserves output and safety tokens before allocating input
space. Packing calls the executor's estimator on the complete request, including
instructions, input/output schemas, upstream results and framing. Executor
implementations must enforce the same limits on retries and any retained history.
`JudgmentExecutor` budgets the actual state/questions/model serialization using
`JudgmentRequestBudget`. Its default conservative UTF-8-byte estimate is an
operating bound, not an exact tokenizer.

`ReducedClassificationPlan<I, O>` classifies bounded chunks independently and
reduces their results in code. Its caller supplies the reduction function and a
versioned reduction identity. Chunk requests share the session's concurrency,
cancellation and durable checkpoints; reduction makes no model request.

`ChunkedClassificationPlan<I, P, O>` uses a direct `I -> O` request when it fits.
Otherwise it runs explicit `I -> P` observations, bounded `PartialObservation<P>
-> P` combination rounds, then `PartialObservation<P> -> O` finalization. Every
stage has a declared schema, instructions, and revision. Reduction requests use
the same context checks. If even a pair of partial observations cannot fit, or a
chunk/round/call limit is exceeded, execution fails without clipping evidence.
The core never infers a union of labels or an average confidence.

Classification nodes of the same output family can form a dependency DAG.
Prerequisite record identities are injected into downstream input/cache keys.
Different input/output families can be scheduled in successive phases in one
session. Discovery of entities or a hierarchy is an application phase, not a
mandatory feature of the scheduler. Direct concurrent calls to `classify` obey
the same global executor concurrency limit as graph jobs.

## Trees

`TreeSource<I>` adds tree discovery and membership freshness to an ordinary
source. It returns a `TreeSnapshot` containing `Node`s. Each node has a stable
key, an optional request for its own input, and child keys. Keys need not be
filesystem paths; `::` is reserved for readable cache keys. Discovery must fail
on an incomplete inventory instead of silently omitting children.

`TreePlan<I, O>` supplies two plan factories: `local` classifies a node's own
input, and `merge` reduces `Part<O>` values from that local result and the
children. Each part contains its key, result (including evidence), and coverage.
Factories can choose different classifiers at different nodes. A merge can be
code-only or use `ChunkedClassificationPlan`; the package assumes no reduction
rule. A node with no own input skips local classification.

```dart
final report = await orchestrator.run((session) => session.runTree(
  source: source,
  request: SourceRequest('catalog'),
  plan: TreePlan(
    id: 'category',
    output: categoryContract,
    local: (node) => localPlan,
    merge: (node) => mergePlan,
  ),
));
```

The scheduler runs independent locals in parallel, then merges from leaves to
root. It shares the session's cancellation, call limits and request checkpoints.
Local and aggregate results have separate keys, such as `docs/user::category::local`
and `docs/user::category`. Parent receipts store child keys and hashes of exactly
the parts consumed. They do not depend on child storage IDs or raw input receipts.
If new input produces the same result, evidence and coverage, propagation stops.

Restoration discovers the current tree and checks each source receipt. Additions,
removals and moves change parent membership. Failed children block their parents;
incomplete coverage propagates through merges. Membership and completed locals
are checked again before returning results, so a change during another branch's
execution cannot be reported as a current aggregate. Completed checkpoints still
survive a failure or cancellation. Applications can retire old task pointers with
`retainTasks(plan.keys(tree))` after successful discovery and validation.

Tina's `/index` uses directory nodes, classifies programming languages only, and
merges supported language labels by union. Input selection stays in its source:
by default it supplies filenames only and uses local extension rules. `/index jev`
selects Typesafe/JEV judgment questions, independently of the chat provider. A complete
result covers that projection, not a read of every file's content.

## Restore and implementation contracts

Sources must include collector/selection/encoder configuration and revisions in
`identity`. Their exposed splitter identity must match the snapshot splitter.
Input values must remain immutable during a run. Freshness receipts should cover
additions, removals, absences, selection changes and transient read failures as
appropriate for that source. The core stores these receipts but does not
interpret them. A source-specific validator must not report unread evidence as
an observed absence.

Coverage is explicit. Partial observations remain partial; an incomplete source
snapshot cannot produce a final `notApplicable` result. Positive or unknown
results may be stored with incomplete coverage. Completeness describes the
source's declared projection: a complete filename projection does not claim
that document contents were inspected.

The final signature includes source, input/output contracts, splitter, plan,
agent/executor, context budget, request and prerequisite identities. Request
checkpoints hash the actual prepared input and store results, evidence locations,
and versioned provenance without raw input text. Final records reference their
request checkpoints. Restart can reuse finished map/reduce requests even if the
final classification was never published. Cached results are schema-decoded;
request checkpoints also revalidate citations against their current input.

Storage writes the content-addressed record before atomically updating its
manifest pointer. Source freshness is checked before final publication. An
interrupted manifest update may leave an unreferenced immutable record. The
application's store supplies writer exclusion and bounded reads; retention/GC
policy is application-owned. Schema v1 project-specific records are cache misses
under schema v2. Neither schema executes restored content as instructions.

Stores may implement `CheckpointStore` to publish a record and its reference in
one transaction and retire task references directly. The orchestrator uses this
interface when available instead of rewriting the full manifest per checkpoint.
Tina's SQLite adapter implements it; the core classifier has no database dependency.
