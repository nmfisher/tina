import 'package:fuzzy_ranker/fuzzy_ranker.dart';

import '../session_commands/session_command_handlers.dart';

/// Offers slash commands for the `/` completion palette. Filters
/// [SessionCommandHandlers.allCommands] by the text typed after the slash:
/// [complete] receives the query *without* its leading `/`, while the results
/// keep theirs (the picker is configured with `prependTriggerOnAccept: false`
/// so it doesn't re-add the trigger).
///
/// Pure and synchronous — the list is small and static, so there is nothing to
/// cache.
class CommandCompletionProvider implements CompletionProvider {
  const CommandCompletionProvider();

  @override
  Future<List<String>> complete(String query) {
    if (query.isEmpty) return Future.value(SessionCommandHandlers.allCommands);
    final prefix = '/$query';
    return Future.value(
      SessionCommandHandlers.allCommands
          .where((c) => c.startsWith(prefix))
          .toList(),
    );
  }
}
