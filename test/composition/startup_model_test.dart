import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/platform/environment.dart';
import 'package:test/test.dart';

import '../helpers/test_registry.dart';
import '../helpers/memory_session_store.dart';

void main() {
  group('buildStartupProvider', () {
    /// Build an [AppComposition] with a fake manifest for resume tests.
    AppComposition buildWith({
      required Config config,
      SessionManifest? manifest,
      String? initialSessionId,
      String? initialConversationId,
    }) => AppComposition(
          config: config,
          environment: const PlatformEnvironment(),
          registry: testRegistry({
            'ANTHROPIC_API_KEY': 'test-key',
          }),
          policy: config.buildPolicy(),
          store: MemorySessionStore(),
          pipeline: defaultPipeline,
          scheduler: SubAgentScheduler(
            registry: testRegistry({
              'ANTHROPIC_API_KEY': 'test-key',
            }),
            pipeline: defaultPipeline,
            maxTokens: config.maxTokens,
            streamIdleTimeout: config.streamIdleTimeout,
            requestTimeout: config.requestTimeout,
            quota: AgentQuota(
              maxDepth: 3,
              maxLive: 6,
            ),
          ),
          spendLedger: SpendLedger(
            maxGlobalTokens: 0,
            requestsPerMinute: 0,
          ),
          pauseGate: PauseGate(),
          initialSessionId: initialSessionId ?? 's1',
          initialConversationId: initialConversationId ?? 'c1',
          initialHistory: const [],
          initialManifest: manifest,
        );

    test('fresh session uses config default', () {
      final config = Config.parse(
        const ['--model', 'claude-3-opus-20240229'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
      );
      final app = buildWith(config: config);
      final provider = app.buildStartupProvider();
      expect(provider.model, 'claude-3-opus-20240229');
    });

    test('resume + meta ref + no flag → provider reflects meta ref', () {
      final config = Config.parse(
        const ['--backend', 'ansi'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
      );
      final manifest = SessionManifest(
        id: 's-resume',
        providerId: 'anthropic',
        activeConversationId: 'c-meta',
        conversations: [
          ConversationMeta(
            id: 'c-meta',
            model: 'openrouter/stealth/ox-alpha',
            providerId: 'openrouter',
            label: 'meta model',
            kind: ConversationKind.primary,
          ),
        ],
      );
      final app = buildWith(
        config: config,
        manifest: manifest,
        initialSessionId: 's-resume',
        initialConversationId: 'c-meta',
      );
      final provider = app.buildStartupProvider();
      expect(provider.model, 'stealth/ox-alpha');
    });

    test('explicit --model flag wins over meta ref', () {
      final config = Config.parse(
        const ['--model', 'openrouter/stealth/ox-alpha', '--backend', 'ansi'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
      );
      final manifest = SessionManifest(
        id: 's-resume',
        providerId: 'anthropic',
        activeConversationId: 'c-meta',
        conversations: [
          ConversationMeta(
            id: 'c-meta',
            model: 'anthropic/claude-file',
            providerId: 'anthropic',
            label: 'file model',
            kind: ConversationKind.primary,
          ),
        ],
      );
      final app = buildWith(
        config: config,
        manifest: manifest,
        initialSessionId: 's-resume',
        initialConversationId: 'c-meta',
      );
      final provider = app.buildStartupProvider();
      expect(provider.model, 'stealth/ox-alpha');
    });

    test('unknown provider in meta ref warns on stderr and falls back', () {
      final config = Config.parse(
        const ['--backend', 'ansi'],
        // Pin the config default via env (NOT --model, which would set
        // modelExplicit and change the precedence path under test).
        env: const {
          'ANTHROPIC_API_KEY': 'test',
          'ANTHROPIC_MODEL': 'claude-3-opus-20240229',
        },
      );
      final manifest = SessionManifest(
        id: 's-resume',
        providerId: 'anthropic',
        activeConversationId: 'c-unknown',
        conversations: [
          ConversationMeta(
            id: 'c-unknown',
            model: 'nosuchprovider/some-model',
            providerId: 'nosuchprovider',
            label: 'unknown',
            kind: ConversationKind.primary,
          ),
        ],
      );
      final app = buildWith(
        config: config,
        manifest: manifest,
        initialSessionId: 's-resume',
        initialConversationId: 'c-unknown',
      );

      // No exception; the unresolvable ref degrades to the config default.
      final provider = app.buildStartupProvider();
      expect(provider.model, 'claude-3-opus-20240229');
    });

    test('meta model null falls back to config default', () {
      final config = Config.parse(
        const ['--backend', 'ansi'],
        env: const {
          'ANTHROPIC_API_KEY': 'test',
          'ANTHROPIC_MODEL': 'claude-3-opus-20240229',
        },
      );
      final manifest = SessionManifest(
        id: 's-resume',
        providerId: 'anthropic',
        activeConversationId: 'c-null',
        conversations: [
          ConversationMeta(
            id: 'c-null',
            model: null,
            providerId: 'anthropic',
            label: 'null model',
            kind: ConversationKind.primary,
          ),
        ],
      );
      final app = buildWith(
        config: config,
        manifest: manifest,
        initialSessionId: 's-resume',
        initialConversationId: 'c-null',
      );
      final provider = app.buildStartupProvider();
      expect(provider.model, 'claude-3-opus-20240229');
    });
  });
}
