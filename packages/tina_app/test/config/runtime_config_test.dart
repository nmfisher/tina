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

  group('--yolo posture (allowAllByDefault)', () {
    test('widens every default to allow, including unmapped tools', () {
      final policy = RuntimeConfig(yolo: true).buildPolicy();
      expect(policy.allowAllByDefault, isTrue);
      // Tools the built-in table allows must stay allowed…
      for (final tool in const [
        'glob',
        'grep',
        'search',
        'ls',
        'stat',
        'which',
        'git',
        'read',
      ]) {
        expect(policy.check(tool, const {}), PermissionDecision.allow,
            reason: '$tool must not regress to ask under --yolo');
      }
      // …tools the table gates must be widened…
      expect(policy.check('fetch', const {'url': 'https://example.com'}),
          PermissionDecision.allow);
      expect(policy.check('web_search', const {'query': 'x'}),
          PermissionDecision.allow);
      expect(policy.check('write', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(policy.check('bash', const {'command': 'git status'}),
          PermissionDecision.allow);
      // …and the unmapped fallback must widen too.
      expect(policy.check('tool_added_after_this_release', const {}),
          PermissionDecision.allow);
    });

    test('an explicit --deny still denies under --yolo', () {
      final policy = RuntimeConfig(
        yolo: true,
        permissionRules: const [
          PermissionRule(
            toolName: 'bash',
            pattern: 'rm *',
            decision: PermissionDecision.deny,
          ),
        ],
      ).buildPolicy();
      expect(policy.check('bash', const {'command': 'rm -rf /tmp/x'}),
          PermissionDecision.deny);
      expect(policy.check('bash', const {'command': 'git status'}),
          PermissionDecision.allow);
    });

    test('without --yolo the built-in defaults apply unchanged', () {
      final policy = RuntimeConfig().buildPolicy();
      expect(policy.allowAllByDefault, isFalse);
      expect(policy.check('glob', const {}), PermissionDecision.allow);
      expect(policy.check('write', const {'filePath': '/x'}),
          PermissionDecision.ask);
      expect(policy.check('fetch', const {}), PermissionDecision.ask);
      expect(policy.check('made_up_tool', const {}), PermissionDecision.ask);
    });

    test('readAll mode is unchanged by the flag', () {
      final policy = RuntimeConfig(
        yolo: true,
        permissionMode: PermissionMode.readAll,
      ).buildPolicy();
      expect(
          policy.check('bash', const {'command': 'git status'}),
          PermissionDecision.deny,
          reason: 'read-all is a hard boundary; --yolo cannot open it');
      expect(policy.check('write', const {'filePath': '/x'}),
          PermissionDecision.deny);
      expect(policy.check('glob', const {}), PermissionDecision.allow);
      expect(policy.check('fetch', const {}), PermissionDecision.allow);
    });

    test('allowEdits mode is unchanged by the flag', () {
      final policy = RuntimeConfig(
        permissionMode: PermissionMode.allowEdits,
      ).buildPolicy();
      expect(policy.allowAllByDefault, isFalse);
      expect(policy.check('write', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(policy.check('edit', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(policy.check('bash', const {'command': 'ls'}),
          PermissionDecision.ask);
    });

    test('safe-mode still strips the dangerous tools before the policy',
        () {
      // safe-mode's guard is tool removal (stripForSafeMode), not the policy
      // table — a permissive policy alone must not resurrect a stripped tool
      // (lib/config.dart: safe-mode "silently dominates --yolo").
      final policy = RuntimeConfig(yolo: true).buildPolicy();
      final survivors = stripForSafeMode([
        _NamedTool('write'),
        _NamedTool('edit'),
        _NamedTool('bash'),
        _NamedTool('read'),
      ]);
      expect(survivors.map((t) => t.schema.name), ['read'],
          reason: 'no stripped tool may survive safe-mode under --yolo');
      // The permissive posture is confined to the policy, which never
      // re-adds a removed tool.
      expect(policy.allowAllByDefault, isTrue);
    });
  });
}

class _NamedTool implements Tool {
  final String name;
  _NamedTool(this.name);

  @override
  ToolSchema get schema => ToolSchema(
        name: name,
        description: 'fake $name',
        inputSchema: const {'type': 'object'},
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    return const ToolResult('ok');
  }
}
