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
No swarm scheduler, tools, UI commands, config-file keys, or changes to current
agent execution are introduced here.

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
  usage is invented. An orchestration budget will need explicit metering here.

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
Next integration should add explicit service configuration/lifecycle, a bounded
swarm scheduler and typed worker task/result contracts. A Choice can select an
allowlisted action, but execution and approval policy must remain in Tina code.
