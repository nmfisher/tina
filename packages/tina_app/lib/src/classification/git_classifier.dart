import 'package:classification/utterance.dart' as classification;
import 'package:tina_core/tina_core.dart' as core;
import 'package:tina_engine/tina_engine.dart' show Message, TextBlock;
export 'package:classification/utterance.dart'
    show
        gitCommands,
        GitIntent,
        gitIntentContract,
        gitClassifier,
        classifyGitInput;

/// Legacy message adapter; classification itself lives in one package.
class InputTextSource extends classification.InputTextSource {
  InputTextSource(String id, String text, List<Message> history)
    : super(id, text, [
        for (final message in history)
          core.Message(
            role: core.Role.values.byName(message.role.name),
            content: [
              for (final block in message.content.whereType<TextBlock>())
                core.TextBlock(block.text),
            ],
          ),
      ]);
}
