import 'package:tina/composition/explore_project.dart';
import 'package:tina/composition/git_input.dart';
import 'package:tina/composition/intent_input.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// PT0 (docs/proposals/plugin-first-tools/01) validation: the launcher's
/// conditional-mounting policy moves INTO the plugins, and explore_project
/// crosses the execution scope like every other registry tool.
///
/// These tests activate a bare execution runtime (no session plugin, no
/// provider build) and inspect the resulting scope directly — the same scope
/// `buildAgent` reads [exploreProjectToolServiceKey] from.
void main() {
  Future<PluginScope> activate(List<PluginDescriptor> plugins) async {
    final runtime = PluginRuntime(
      name: 'pt0-test',
      plugins: [
        spendLedgerPlugin(RuntimeConfig(provider: 'test', model: 'a')),
        ...plugins,
      ],
    );
    await runtime.activate();
    return runtime.scope;
  }

  test('git/intent input plugins self-gate: headless contributes nothing',
      () async {
    final scope = await activate([
      configuredGitInputPlugin(const {}, interactive: false),
      configuredIntentInputPlugin(const {}, interactive: false),
    ]);
    expect(
      scope.contributions.where((c) => c.contribution is GitInput),
      isEmpty,
    );
    expect(
      scope.contributions.where((c) => c.contribution is IntentInput),
      isEmpty,
    );
  });

  test('git/intent input plugins mount interactive surfaces', () async {
    final scope = await activate([
      configuredGitInputPlugin(const {}, interactive: true),
      configuredIntentInputPlugin(const {}, interactive: true),
    ]);
    expect(
      scope.contributions.where((c) => c.contribution is GitInput),
      isNotEmpty,
    );
    expect(
      scope.contributions.where((c) => c.contribution is IntentInput),
      isNotEmpty,
    );
  });

  test('explore_project crosses the scope as a typed tool', () async {
    final scope = await activate([
      configuredExploreProjectPlugin(env: const {}, pauseGate: PauseGate()),
    ]);
    final tool = scope.lookup(exploreProjectToolServiceKey);
    expect(tool, isA<ExploreProjectTool>());
  });

  test('explore_project plugin requires the ledger (ordering contract)',
      () async {
    // Without a ledger provider the composition must fail fast — the
    // activation order pins the tool after metering exists.
    final runtime = PluginRuntime(
      name: 'pt0-test-ledgerless',
      plugins: [
        configuredExploreProjectPlugin(env: const {}, pauseGate: PauseGate()),
      ],
    );
    await expectLater(
      runtime.activate(),
      throwsA(isA<PluginCompositionError>()),
    );
  });
}
