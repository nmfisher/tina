import 'package:fuzzy_ranker/fuzzy_ranker.dart';

import '../session_commands/session_command_handlers.dart';

/// Offers slash commands for the `/` completion palette. Filters the ordered
/// live command registry supplied by the frontend by the text after the slash:
/// [complete] receives the query *without* its leading `/`, while the results
/// keep theirs (the picker is configured with `prependTriggerOnAccept: false`
/// so it doesn't re-add the trigger).
///
/// Reads the live list on every completion, including plugin registrations and
/// removals. The default is a compatibility catalog for standalone callers.
class CommandCompletionProvider implements CompletionProvider {
  final List<String> Function()? names;
  const CommandCompletionProvider({this.names});

  @override
  Future<List<String>> complete(String query) {
    final names = this.names?.call() ?? SessionCommandHandlers.registry.allNames;
    if (query.isEmpty) return Future.value(names);
    final prefix = '/$query';
    return Future.value(
      names.where((c) => c.startsWith(prefix)).toList(),
    );
  }
}
