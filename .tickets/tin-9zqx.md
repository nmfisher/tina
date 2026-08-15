---
id: tin-9zqx
status: closed
deps: []
links: []
created: 2026-08-14T00:00:00Z
type: proposal
priority: 2
assignee: Nick Fisher
tags: [composition, app-provider, refactor, proposal]
closed: 2026-08-15
---
# AppComposition: is LlmProvider in the wrong place? (simplification options)

## Context

A design review of lib/composition/app_composition.dart found one field that does not fit: `AppComposition.provider` (the startup LlmProvider).

AppComposition is described as "the assembled non-UI world shared by every frontend" — session-long infrastructure: config, environment, provider registry, permission policy, session store, agent pipeline, sub-agent scheduler, spend ledger, pause gate. All of those outlive conversations.

The LlmProvider is different. It is conversation-scoped runtime state:

1. **Scope mismatch.** It is really "the first conversation's provider" — resolved once from config.provider/config.model (lib/composition/app_composition.dart:92-100) before any conversation exists. Other conversations build and close their own providers via the registry (lib/session_manager.dart `_buildConversation`; close sites at :312, :335, :403). The composition holds one orphan product of that lifecycle.

2. **The factory already sits next to it.** ProviderRegistry is the provider factory and it is already a composition field. Holding both the factory and one specific product of it is redundant. No other conversation gets its provider from the composition.

3. **It is the initial conversation's provider, not the app's.** Both frontends use it for the FIRST conversation: headless --prompt (bin/tina.dart:349 passes it to buildAgent; :303/:332/:389 close it), the TUI (lib/tui_coordinator.dart:247 reads app.provider; used for the initial agent at :506, the initial Conversation at :520, recorder metadata at :487), and the summary fleet (lib/summaries/summary_runner.dart:147, :165). It also doubles as the account-provider fallback for restored conversations with no stored model ref (lib/tui_coordinator.dart:585 → lib/persistence/session_restore.dart:111). Later conversations build their own providers via SessionManager.

4. **Ambiguous meaning.** `app.provider` reads as "the app's provider" but means "the initial conversation's provider". The summary fleet reuses that same conversation-scoped instance, which is conceptually wrong.

5. **Two lifecycle models.** TUI closes providers per-conversation; headless closes the composition's one. Same thing, two ownership models.

6. **Wasted builds.** The headless --workflow path (bin/tina.dart:280-307) and the /index path (:316-336) build and close app.provider (:303, :332) without ever using it.

7. **Double-close hazard.** On resume, a restored conversation with no stored model ref reuses the startup provider instance (lib/persistence/session_restore.dart:111, via the accountProvider threaded at lib/tui_coordinator.dart:585) — the same instance the initial conversation holds. closeAll closes it per-conversation (lib/session_manager.dart:403), and concrete providers close their HTTP client (packages/tina_engine/lib/src/llm/anthropic.dart:36). Double close.

Why it is there (the defense): the headless path has no conversation manager and needs a provider handed to it; tests inject fakes via the `provider:` param of buildAppComposition; the ledger must be created before any provider so the metering decorator wraps it (app_composition.dart:85-91) — that ordering is already guaranteed by the composition, so moving provider construction out does not break metering.

## Task (PROPOSAL-ONLY)

Analyze the code and write a proposal document at docs/proposals/app_composition_provider.md. It must give MULTIPLE options for simplifying the design, including:

1. At least 3 concrete restructurings. Examples to evaluate (not a limit): move startup-provider construction to the entry points; introduce a "resolved initial conversation" object that owns the provider; build-on-demand from the registry; keep-as-is with honest rationale; anything else you see.
2. Concrete RENAME suggestions for AppComposition and its fields if the name no longer fits the shape (e.g. AppContext, AppBootstrap, SessionAssembly, ...). Evaluate honestly — say which names fit and which do not.
3. For each option: what changes, what breaks, rough effort, and a recommendation.

Verify every claim against the code. Cite file:line for each fact. The proposal must be written in simplified technical English (short sentences, plain words, no jargon).

## Progress note

First sandbox run (2026-08-14, GLM): the agent completed the full code analysis but the permission layer blocked every write, so nothing was committed. Its verified findings are merged into the Context section above (items 3, 6, 7). The relaunch resumes the agent's prior session with write permissions granted; it should finish the task: write the proposal doc, update this ticket via tk, commit, push, and raise the PR.

## Agent rules

- PROPOSAL ONLY. Do NOT change code or tests. No builds, no test runs, no installs.
- Update this ticket with tk: start when you begin, close when done.
- Commit all work locally on this branch (asb/app-provider-simplify).
- Push the branch and raise a PR when finished. Never merge the PR. Never commit or push to main/master, in this repo or in dependency repos.
- If you need to read or change a private git dependency, clone it from the remote into the container yourself (git clone https://github.com/<org>/<repo>.git). Do not rely on a local checkout existing.
- Write the proposal in simplified technical English.

## Acceptance Criteria

- docs/proposals/app_composition_provider.md exists and contains: at least 3 restructuring options, file:line citations for every claim, concrete rename suggestions, and effort + recommendation per option.
- No code or test changes in the branch (proposal doc + ticket status only).
- Ticket status closed via tk. Branch pushed, PR raised.

## Outcome (2026-08-15)

Proposal written to docs/proposals/app_composition_provider.md. Four options evaluated (keep+rename, move-to-entry-points, initial-conversation object, build-on-demand factory) plus one rejected. Recommendation: Option D — a `buildStartupProvider()` factory method on the composition. Class name `AppComposition` kept; field renamed by the method.

Corrections to the Context section, found during verification:

- Point 3 is wrong: the TUI DOES read `app.provider` (lib/tui_coordinator.dart:247, :487, :506, :520, :585). It is the initial conversation's provider; only later conversations build their own.
- Point 5 understates it: there are three close paths (TUI conversation-owned, headless direct, fleet ephemeral), not two.
- New finding: the headless `--workflow` and `/index` paths build and close `app.provider` without ever using it (bin/tina.dart:303, :332).
- New finding: the resume restore fallback can share the startup provider instance between two conversations (lib/persistence/session_restore.dart:111, :117), so `closeAll` closes it twice (lib/session_manager.dart:403).
