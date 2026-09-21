# classifier

The package provides structured judgments, exploration, and a domain-independent
classification API. Import `package:classifier/classification.dart` for the typed
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
- `ClassificationExecutor` binds requests to an agent runtime and estimates the
  complete serialized request. No particular model API is built into this layer.
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
  executor: agentExecutor,
).run((session) => session.classify(task));
```

`catalogSource`, `categoryClassifier`, `store`, and `agentExecutor` above are
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
The engine adapter uses a conservative UTF-8-byte estimate and an engine guard
on every actual request; this is an operating bound, not an exact tokenizer.

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
by default it supplies filenames and selected manifest contents. A complete
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
