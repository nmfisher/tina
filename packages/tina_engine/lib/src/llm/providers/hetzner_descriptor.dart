import '../openai_compatible.dart';
import '../registry.dart';

/// Hetzner Inference — OpenAI-compatible managed inference serving Qwen models
/// behind `https://inference.hetzner.com/api/v1` (confirmed by models.dev's
/// provider entry, which also records the npm SDK as
/// `@ai-sdk/openai-compatible` — i.e. the plain OpenAI `/chat/completions`
/// wire format; no custom wire code is needed).
///
/// Endpoint / auth facts verified 2026-08-19:
/// - `POST /api/v1/chat/completions` and `GET /api/v1/models` both return
///   `401 {"error":"unauthorized"}` (Bearer-only); `GET /api/v1/v1/models`
///   returns 404, so the base URL must omit the trailing `/v1` (see
///   [defaultBaseUrl]).
/// - Auth: `Authorization: Bearer <token>`. The Hetzner web playground obtains
///   this via OIDC, but for CLI/programmatic use Hetzner exposes a persistent
///   access/API token sent as a Bearer header — the same shape every other
///   OpenAI-compatible provider here uses. Set `HETZNER_API_KEY` (or
///   `[providers.hetzner] api_key` in `~/.tina/config`).
///
/// Model set is small and slow-moving (models.dev records `modelCount: 2` as
/// served by Hetzner), and both ids below are taken from models.dev's
/// `alibaba/qwen3.*` entries — the models Hetzner actually serves. They are
/// NOT aliased through the models.dev overlay (that maps `alibaba` to the
/// `qwen` builtin, not `hetzner`), so this compiled map is the source of truth
/// for Hetzner. `listsRemoteModels: true` still fetches Hetzner's own
/// `/v1/models` at startup to surface any newly-added ids ahead of a release.
final ProviderDescriptor hetznerDescriptor = ProviderDescriptor(
  id: 'hetzner',
  name: 'Hetzner',
  authSources: const [AuthSource('HETZNER_API_KEY', AuthScheme.bearerToken)],
  // Deliberately omits the trailing `/v1`: [OpenAiCompatibleAdapter.chatEndpoint]
  // appends `/v1/chat/completions` when the base doesn't already end in `/v<digits>`,
  // and [LiveModelsCatalog._modelsUri] appends `/v1/models`. Both then resolve to
  // the verified routes (`/api/v1/chat/completions`, `/api/v1/models`). A versioned
  // base (`.../api/v1`) would make the live listing hit the verified-404
  // `/api/v1/v1/models`.
  defaultBaseUrl: 'https://inference.hetzner.com/api',
  builder: openAiCompatibleBuilder('Hetzner'),
  listsRemoteModels: true,
  models: const {
    // Hetzner's current Qwen catalog, with metadata sourced from models.dev's
    // `alibaba/qwen3.*` records (verified 2026-08-19; both updated 2026-08-14).
    // Ordering puts the newest flagship first so it is the default model when
    // none is chosen.
    'qwen3.8-27b': ModelInfo(
      id: 'qwen3.8-27b',
      name: 'Qwen3.8 27B',
      contextWindow: 262144,
      maxOutput: 32768,
      supportsVision: true,
    ),
    'qwen3.6-35b-a3b': ModelInfo(
      id: 'qwen3.6-35b-a3b',
      name: 'Qwen3.6 35B-A3B',
      contextWindow: 262144,
      maxOutput: 65536,
      supportsVision: true,
    ),
  },
);
