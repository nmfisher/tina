import 'package:tina_engine_2/tina_engine_2.dart';

import '../memory_store_api.dart';
import 'answer_cache.dart';
import 'hot_tier.dart';
import 'memory_tools.dart';

/// Owns the memory pair and contributes the tools, the hot tier and
/// the answer cache (issue 94 phases 1-2). The assembly supplies the
/// opener (origin-keyed sqlite natively, an injected implementation
/// under wasm — the channel-plugin composition seam); the plugin
/// injects the hot tier at session start, mounts the tools, and
/// exposes its answer cache so the process runner can capture and
/// serve exploratory searches.
final class MemoryPlugin extends AgentPlugin {
  MemoryPlugin({
    required this.openStores,
    this.sessionId,
    this.answerFileSystem,
  });

  /// Opens the memory pair for this workspace.
  final MemoryStorePair Function() openStores;

  /// The session id that stamps every write (updated_by); null means
  /// the opening session's own id (the composition default).
  final String? sessionId;

  /// The answer cache's filesystem seam (tests inject a fake disk).
  final AnswerFiles? answerFileSystem;

  MemoryStorePair? _pair;
  MemoryTools? _tools;
  AnswerCache? _cache;
  String? _sessionId;

  /// The answer cache, once the session has opened (the process
  /// runner's capture/serve point).
  AnswerCache? get answerCache => _cache;

  /// The pair a UI may borrow for reads; null before the session
  /// opens. A borrower reads through the interface and never closes
  /// these stores.
  MemoryStorePair? get storesForUi => _pair;

  @override
  String get id => 'tina/memory';

  @override
  List<ToolSchema> get tools => _tools?.tools ?? const [];

  @override
  SessionSeed? openSession(PluginSession session) {
    final pair = openStores();
    _pair = pair;
    _sessionId = sessionId ?? session.id;
    _tools = MemoryTools(pair, sessionId: _sessionId!);
    _cache = AnswerCache(
        persister: MemoryAnswerPersister(pair.project),
        fileSystem: answerFileSystem,
        // The scoreboard persists through the project tier: counter
        // deltas accumulate in the store's answer_cache_stats table,
        // so `tina memory stats` reads numbers that survive sessions.
        // Best effort — telemetry must never break a session.
        onCounters: (delta) {
          try {
            pair.project.bumpAnswerCache(delta, MemoryScope.project);
          } on Object {
            // Persisted counters are a convenience; a store that
            // cannot write keeps the session-only view.
          }
        });
    return null;
  }

  @override
  void mountOn(AgentLoop loop) => _tools?.mountOn(loop);

  /// Test/direct-execution surface (the loop's executor calls the
  /// same path).
  Future<ToolResult> executeForTest(String name, Map<String, Object?> input) =>
      _tools!.execute(name, input);

  @override
  void onPrompt(TurnContext context) {
    _tools?.onPrompt(context);
    // Session-start hot tier (issue 94): the hottest entries ride the
    // FIRST prompt; later turns carry only the etiquette section.
    if (_hotTierInjected) return;
    _hotTierInjected = true;
    final block = _pair == null ? null : hotTierBlock(_pair!);
    if (block != null) context.promptSections.add(block);
  }

  var _hotTierInjected = false;

  @override
  void closeSession() {
    _cache = null;
    _tools = null;
    _pair?.close();
    _pair = null;
    _hotTierInjected = false;
  }
}
