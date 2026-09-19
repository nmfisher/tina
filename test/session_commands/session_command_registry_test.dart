import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/tina_app.dart';

import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Minimal [Agent] for command-registry tests — never runs a turn.
Agent _fakeAgent(LlmProvider provider, FakeHostInterface host) => Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: host,
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      system: '',
    );

/// A [CommandContext] fake carrying a *mutable* [commandHooks] map, so tests
/// can register hooks and assert they fire (before the handler, keyed by the
/// typed word). Members no command under test touches throw on access.
class _HookCtx implements CommandContext {
  _HookCtx(this.conversation);

  final Conversation conversation;

  final Map<String, FutureOr<void> Function()> hooks = {};

  @override
  Conversation get active => conversation;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => hooks;

  /// Null = headless: `/detach` reports its warning instead of detaching.
  @override
  Future<void> Function()? get detachTmux => null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

({Conversation conv, FakeHostInterface host, _HookCtx ctx}) _fixture() {
  final host = FakeHostInterface();
  final provider = FakeProvider.always(model: 'test-model');
  final conv = Conversation(
    id: 'test-conv',
    label: 'test-model',
    agent: _fakeAgent(provider, host),
    provider: provider,
    host: host,
    policy: PermissionPolicy(),
  );
  return (conv: conv, host: host, ctx: _HookCtx(conv));
}

/// Golden `/help` output, originally extracted from `_printHelp` and updated
/// for intentional help-text changes. Both dispatch and direct rendering from
/// [SessionCommandRegistry] must preserve the expected output.
void main() {
  group('golden /help output', () {
    test('matches the expected command help', () async {
      final f = _fixture();
      await SessionCommandHandlers(f.ctx).dispatch('/help');

      const expected = 'Commands:\n'
          '  /help          show this list\n'
          '  /branch        fork the active conversation into a new panel '
          '(copies its history)\n'
          '  /clear         reset this session\'s history\n'
          '  /compact       summarize history to free context\n'
          '  /auto-compact  show/set the auto-compact threshold (off|<n>)\n'
          '  /model         pick a provider/model for the active session\n'
          '  /image <path>  render an image in the focused panel\n'
          '  /index         refresh the per-directory summary index '
          '(staleness-aware, runs in the background)\n'
          '  /workflow      list/show/new/edit/run DOT pipelines '
          '(/workflow show|new|edit|run <name>)\n'
          '  /permissions   show permission rules; /permissions <mode> '
          'switches mode\n'
          '                 (ask | read-all | allow-edits | auto)\n'
          '  /sessions      open the session picker (switch/resume); lists '
          'them headless\n'
          '  /session       list live sessions; new/switch/close\n'
          '  /resume <id>   load a saved session into the active session\n'
          '  /save <path>   export this session as a markdown transcript\n'
          '  /settings      configure providers, models and live quotas '
          '(theme needs restart)\n'
          '  /update        check GitHub for a newer release and install it\n'
          '  /prompts       edit each agent role\'s system prompt (applies on '
          'restart)\n'
          '  /exit          quit (inside tmux: Detach / Exit / Cancel)\n'
          '  /detach        return to the shell, keep the agent running '
          '(tmux; also Alt+D)\n'
          '  /explore <implementation question> locate code using Typesafe scouts (no direct filesystem tools)\n'
          'ESC cancels the active session\'s in-flight response.\n';

      // Dispatch echoes the trimmed line, then a separator, then the block.
      expect(f.host.messages, ['/help\n', expected]);
      expect(f.host.separators, 1);
    });

    test('the renderer reproduces the same bytes without dispatching', () {
      expect(SessionCommandHandlers.registry.renderHelp(),
          _goldenHelpBody());
    });
  });

  group('SessionCommandRegistry structure', () {
    test('flattened names == the old allCommands list, in order', () {
      expect(SessionCommandHandlers.allCommands,
          SessionCommandHandlers.registry.allNames);
    });

    test('contains the supported command names in completion order', () {
      expect(
        SessionCommandHandlers.registry.allNames,
        [
          '/explore', '/exit', '/quit', '/help', '/clear', '/compact', '/auto-compact',
          '/permissions', '/sessions', '/session', '/resume', '/save',
          '/model', '/settings', '/prompts', '/spawn', '/branch', '/image',
          '/index', '/workflow', '/output', '/spend', '/update', '/detach',
        ],
      );
    });

    test('every entry exposes argsHint and summary metadata', () {
      for (final entry in SessionCommandHandlers.registry.commands) {
        expect(entry.argsHint, isNotNull,
            reason: '${entry.primary} is missing argsHint');
        expect(entry.summary, isNotNull,
            reason: '${entry.primary} is missing summary');
        expect(entry.names, isNotEmpty);
      }
    });

    test('/quit is an alias of /exit (primary-first naming)', () {
      final exit = SessionCommandHandlers.registry.lookup('/exit');
      expect(exit, isNotNull);
      expect(exit!.names, ['/exit', '/quit']);
      expect(identical(exit, SessionCommandHandlers.registry.lookup('/quit')),
          isTrue);
    });

    test('lookup misses return null for unknown and non-slash words', () {
      expect(SessionCommandHandlers.registry.lookup('/savee'), isNull);
      expect(SessionCommandHandlers.registry.lookup('hello'), isNull);
    });
  });

  group('dispatch through the registry', () {
    test('/exit and /quit both produce CmdExit from the shared entry',
        () async {
      for (final word in ['/exit', '/quit']) {
        final f = _fixture();
        final result = await SessionCommandHandlers(f.ctx).dispatch(word);
        expect(result, isA<CmdExit>(), reason: word);
      }
    });

    test('the pre-dispatch hook fires for aliases, keyed by the typed word',
        () async {
      final fired = <String>[];
      final f = _fixture();
      f.ctx.hooks['/quit'] = () => fired.add('quit-hook');
      f.ctx.hooks['/exit'] = () => fired.add('exit-hook');

      await SessionCommandHandlers(f.ctx).dispatch('/quit');
      expect(fired, ['quit-hook'],
          reason: 'hooks are keyed by the typed word — /quit fires the /quit '
              'hook, not the /exit one');
    });

    test('the pre-dispatch hook runs before the handler', () async {
      final f = _fixture();
      final observed = <String>[];
      f.ctx.hooks['/clear'] = () => observed.add(
          f.host.messages.any((m) => m.contains('(history cleared)'))
              ? 'after'
              : 'before');

      await SessionCommandHandlers(f.ctx).dispatch('/clear');

      // The hook saw no cleared-marker yet; the default handler still ran
      // after it and recorded the marker.
      expect(observed, ['before']);
      expect(f.host.messages.last, '(history cleared)\n');
    });

    test('a hook-less command still reaches its handler (registry invoke)',
        () async {
      final f = _fixture();
      final result = await SessionCommandHandlers(f.ctx).dispatch('/detach');
      expect(result, isA<CmdHandled>());
    });

    test("an unknown slash command prints the exact error wording", () async {
      final f = _fixture();
      // Args included: the typed *word* (not the line) names the error.
      final result = await SessionCommandHandlers(f.ctx).dispatch('/savee nope');
      expect(result, isA<CmdHandled>());
      expect(
        f.host.styledMessages.single.message,
        '/savee: unknown command\n',
      );
      expect(
        f.host.styledMessages.single.style,
        HostMessageStyle.error,
      );
      expect(f.host.separators, 0,
          reason: 'unknown commands do not echo or separate');
    });

    test('a non-slash input is CmdNotCommand and prints nothing', () async {
      final f = _fixture();
      final result =
          await SessionCommandHandlers(f.ctx).dispatch('hello there');
      expect(result, isA<CmdNotCommand>());
      expect(f.host.messages, isEmpty);
      expect(f.host.separators, 0);
    });

    test('echo + separator ordering is preserved for a registry command',
        () async {
      final f = _fixture();
      await SessionCommandHandlers(f.ctx).dispatch('/clear');
      expect(f.host.messages.first, '/clear\n',
          reason: 'the trimmed line is echoed verbatim');
      expect(f.host.separators, 1);
    });
  });

  group('feature-gated commands (configureFeatures)', () {
    // configureFeatures rewrites the shared static registry, so every test
    // here restores the full table for its neighbours (the golden /help tests
    // above render the full table, /workflow included).
    tearDown(() => SessionCommandHandlers.configureFeatures(workflow: true));

    test('a disabled feature vanishes from dispatch, help, and completion',
        () {
      // Gating in the registry rather than in the handler is the point: one
      // answer, so a command can never be offered by the completion palette
      // and then rejected by dispatch.
      SessionCommandHandlers.configureFeatures(workflow: false);
      final r = SessionCommandHandlers.registry;
      expect(r.lookup('/workflow'), isNull, reason: 'not dispatchable');
      expect(r.allNames, isNot(contains('/workflow')),
          reason: 'not completable');
      expect(r.renderHelp(), isNot(contains('/workflow')),
          reason: 'not listed in /help');
      // Everything else is untouched.
      expect(r.lookup('/help'), isNotNull);
      expect(r.allNames, contains('/help'));
    });

    test('enabling the feature restores it on all three surfaces', () {
      SessionCommandHandlers.configureFeatures(workflow: true);
      final r = SessionCommandHandlers.registry;
      expect(r.lookup('/workflow'), isNotNull);
      expect(r.allNames, contains('/workflow'));
      expect(r.renderHelp(), contains('/workflow'));
    });
  });

}

/// The golden help block (shared by the two golden tests above).
String _goldenHelpBody() =>
    'Commands:\n'
        '  /help          show this list\n'
        '  /branch        fork the active conversation into a new panel '
        '(copies its history)\n'
        '  /clear         reset this session\'s history\n'
        '  /compact       summarize history to free context\n'
        '  /auto-compact  show/set the auto-compact threshold (off|<n>)\n'
        '  /model         pick a provider/model for the active session\n'
        '  /image <path>  render an image in the focused panel\n'
        '  /index         refresh the per-directory summary index '
        '(staleness-aware, runs in the background)\n'
        '  /workflow      list/show/new/edit/run DOT pipelines '
        '(/workflow show|new|edit|run <name>)\n'
        '  /permissions   show permission rules; /permissions <mode> '
        'switches mode\n'
        '                 (ask | read-all | allow-edits | auto)\n'
        '  /sessions      open the session picker (switch/resume); lists '
        'them headless\n'
        '  /session       list live sessions; new/switch/close\n'
        '  /resume <id>   load a saved session into the active session\n'
        '  /save <path>   export this session as a markdown transcript\n'
        '  /settings      configure providers, models and live quotas '
        '(theme needs restart)\n'
        '  /update        check GitHub for a newer release and install it\n'
        '  /prompts       edit each agent role\'s system prompt (applies on '
        'restart)\n'
        '  /exit          quit (inside tmux: Detach / Exit / Cancel)\n'
        '  /detach        return to the shell, keep the agent running '
        '(tmux; also Alt+D)\n'
        '  /explore <implementation question> locate code using Typesafe scouts (no direct filesystem tools)\n'
        "ESC cancels the active session's in-flight response.\n";
