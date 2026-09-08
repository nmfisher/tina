import 'package:test/test.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  test('runtime collections are defensive immutable snapshots', () {
    final rules = <PermissionRule>[];
    final prompts = {'main': 'original'};
    final config = RuntimeConfig(
      permissionRules: rules,
      promptOverrides: prompts,
    );
    rules.add(
      const PermissionRule(
        toolName: 'bash',
        pattern: '*',
        decision: PermissionDecision.deny,
      ),
    );
    prompts['main'] = 'changed';
    expect(config.permissionRules, isEmpty);
    expect(config.promptOverrides['main'], 'original');
    expect(() => config.permissionRules.clear(), throwsUnsupportedError);
    expect(() => config.promptOverrides.clear(), throwsUnsupportedError);
  });

  test('policy and budget instances remain execution-local', () {
    final config = RuntimeConfig(
      yolo: true,
      permissionMode: PermissionMode.readAll,
      maxTurnTokens: 0,
      maxSessionTokens: 42,
      maxRequestTokens: 0,
    );
    final first = config.buildPolicy();
    first.mode = PermissionMode.auto;
    expect(config.buildPolicy().mode, PermissionMode.readAll);
    expect(config.buildTokenBudget()!.perSessionLimit, 42);
    expect(
      RuntimeConfig(
        maxTurnTokens: 0,
        maxSessionTokens: 0,
        maxRequestTokens: 0,
      ).buildTokenBudget(),
      isNull,
    );
    expect(
      RuntimeConfig(apiKey: 'secret').toString(),
      isNot(contains('secret')),
    );
  });
}
