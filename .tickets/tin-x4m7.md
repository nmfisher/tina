---
id: tin-x4m7
status: closed
deps: []
links: []
created: 2026-08-14T00:00:00Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [providers, cerebras, registry, feature]
---
# Add Cerebras as a built-in provider

## Context

Cerebras Inference (the Cerebras platform) just announced support for the Qwen3-827B model. The tina registry should offer Cerebras as a built-in provider, with Qwen3-827B and every other model the platform currently serves.

Cerebras exposes an OpenAI-compatible API. The codebase already has a clean pattern for exactly this kind of provider — a single descriptor file:

- Template: packages/tina_engine/lib/src/llm/providers/grok_descriptor.dart (the simplest OpenAI-compatible example: ProviderDescriptor with id, name, authSources, defaultBaseUrl, openAiCompatibleBuilder, models catalog).
- Registration: packages/tina_engine/lib/src/llm/providers/builtins.dart — add the import and `..register(...)` line.
- ModelInfo: id, name, contextWindow, maxOutput per model (see the catalog entries in any existing descriptor).
- Auth: the env-var convention `<PREFIX>_API_KEY` with AuthScheme.bearerToken (see grok's XAI_API_KEY) — for Cerebras that should be CEREBRAS_API_KEY.

## Task

1. Research the Cerebras platform from its public docs/API (network is available in the container): confirm the API base URL, the auth scheme, and the CURRENT model list (model ids, context window, max output where published). The announced Qwen3-827B model MUST be in the catalog; include every other model the platform offers at the time of writing.
2. Add packages/tina_engine/lib/src/llm/providers/cerebras_descriptor.dart following the existing pattern.
3. Register it in builtins.dart.
4. Add tests following the existing test conventions (see test/llm/ for registry/descriptor tests).
5. Run the relevant tests and dart analyze; all must pass.

## Acceptance Criteria

- cerebras_descriptor.dart exists, follows the house pattern, and is registered in builtins.dart.
- Catalog contains qwen3-827b and all other Cerebras models current at the time of writing, with accurate ids and context windows (verified against the platform, cite the source in the PR description).
- Tests cover the descriptor (catalog contents, auth env mapping, base URL). Tests and dart analyze pass.
- Ticket closed via tk. Branch pushed, PR raised, nothing merged.

## Agent rules

- This is an IMPLEMENTATION task, not a proposal. Code and test changes are expected.
- Update this ticket with tk: start when you begin, close when done.
- Commit all work locally on this branch (asb/add-cerebras-provider).
- Push the branch and raise a PR when finished. Never merge the PR. Never commit or push to main/master, in this repo or in dependency repos.
- If you need to read or change a private git dependency, clone it from the remote into the container yourself (git clone https://github.com/<org>/<repo>.git). Do not rely on a local checkout existing.
- Write the PR description in simplified technical English (short sentences, plain words, no jargon). Cite the Cerebras source you verified the model list against.

## Outcome notes (2026-08-15)

Implemented as specified, with ONE deviation:

**`qwen3-827b` was NOT added — the model does not exist on the platform.**
Verified against the authoritative source, the public models API
(`https://api.cerebras.ai/public/v1/models`, fetched 2026-08-15):

- It returns exactly three models: `gpt-oss-120b`, `gemma-4-31b`, `zai-glm-4.7`.
- `GET /public/v1/models/qwen3-827b` returns `{"detail":"Model 'qwen3-827b' not found or not publicly available"}`.
- The changelog (https://inference-docs.cerebras.ai/support/change-log) has no mention of a Qwen3-827B at any point; all Qwen models (qwen-3-32b, qwen-3-235b-a22b*, qwen-3-coder-480b) were deprecated in 2025 with migrations to GPT OSS 120B / GLM 4.7.
- Web search finds no such announcement from Cerebras or Qwen. The premise in Context appears mistaken (possibly conflating Qwen3-235B or Qwen3-8B).

Rather than fabricate a model id with invented specs — which would ship a catalog entry that fails on every real request — the catalog contains the three models the platform actually serves. If Qwen3-827B does land later, it is a one-entry addition to `cerebras_descriptor.dart`.

Everything else done: descriptor + registration + export, tests (catalog contents, auth env mapping, base URL, build/resolve), `dart analyze` clean on all touched files (the 5414 repo-wide analyzer warnings are pre-existing), all tina_engine llm tests pass. Note: root-package tests cannot run in this container (tina requires SDK ^3.12.0, container has 3.11.0) — pre-existing, unrelated to this change.
