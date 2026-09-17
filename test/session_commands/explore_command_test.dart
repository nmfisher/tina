import 'dart:async';
import 'package:test/test.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

class Context implements CommandContext {
  @override
  final Conversation active;
  Context(this.active);
  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    '/explore dispatches a normal turn with a restricted registry',
    () async {
      final host = FakeHostInterface();
      addTearDown(host.dispose);
      final provider = FakeProvider.always(model: 'm');
      final tools = ToolRegistry([ExploreProjectTool(open: () => null)]);
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: host,
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: '',
      );
      final conversation = Conversation(
        id: 'c',
        label: 'c',
        agent: agent,
        provider: provider,
        host: host,
        policy: PermissionPolicy(),
      );
      final handler = SessionCommandHandlers(Context(conversation));
      final result = await handler.dispatch(
        '/explore where is authentication?',
      );
      expect(result, isA<CmdRun>());
      final prompt = (result as CmdRun).prompt;
      expect(prompt, contains('where is authentication?'));
      final scoped = explorationToolsForTurn(tools, prompt)!;
      expect(scoped['explore_project'], same(tools['explore_project']));
      expect(scoped.executionBlock('read', {}), isNotNull);
      expect(scoped.executionBlock('delegate', {}), isNotNull);
      expect(explorationToolsForTurn(tools, 'normal turn'), isNull);
      expect(await handler.dispatch('/explore'), isA<CmdHandled>());
      expect(host.messages.join(), contains('Usage: /explore'));
    },
  );
}
