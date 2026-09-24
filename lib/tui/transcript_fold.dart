import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina_engine/tina_engine.dart';

/// `/blocks`, `/show`, `/hide` — fold the conversation behind [host]'s
/// transcript in place. The blocks themselves are the sink's; this only maps
/// a command onto them and reports what changed.
///
/// Lives here so the command semantics are testable without a coordinator or
/// an editor: [host] is the only state this reads, and every reply goes back
/// through it.
Future<void> foldTranscriptCommand(
  TuiConversationHost host, {
  required String verb,
  required String argument,
}) async {
  final transcript = host.transcript;

  void report(String message) =>
      host.showMessage(message, style: HostMessageStyle.dim);

  if (verb == 'list') {
    final indexes = transcript.foldableIndexes;
    if (indexes.isEmpty) {
      report('nothing to fold yet.\n');
      return;
    }
    final lines = StringBuffer('foldable blocks:\n');
    for (var n = 0; n < indexes.length; n++) {
      final block = transcript.blocks[indexes[n]];
      lines.writeln(
        '  ${n + 1}. '
        '${block.folded ? '▸' : '▾'} ${blockSummary(block)}',
      );
    }
    lines.write(
      '  /show <n> reveals one, /hide <n> closes it, '
      'or use "all".\n',
    );
    report(lines.toString());
    return;
  }

  final indexes = transcript.foldableIndexes;
  if (argument == 'all') {
    final changed = transcript.setAllFolds(folded: verb == 'hide');
    report(
      changed == 0
          ? 'nothing to ${verb == 'hide' ? 'fold' : 'unfold'}.\n'
          : '$changed block${changed == 1 ? '' : 's'} '
              '${verb == 'hide' ? 'folded' : 'revealed'}.\n',
    );
    return;
  }

  final n = int.tryParse(argument);
  if (n == null || n < 1 || n > indexes.length) {
    report(
      'no block $argument — /blocks lists '
      '${indexes.length} foldable block${indexes.length == 1 ? '' : 's'}.\n',
    );
    return;
  }
  final index = indexes[n - 1];
  final block = transcript.blocks[index];
  // `show` on an open block and `hide` on a closed one are no-ops: say so
  // rather than flipping it the wrong way.
  if (block.folded == (verb == 'show')) {
    transcript.toggleFold(index);
    report('block $n ${verb == 'show' ? 'revealed' : 'folded'}.\n');
    return;
  }
  report(
    'block $n is already '
    '${verb == 'show' ? 'open' : 'folded'}.\n',
  );
}
