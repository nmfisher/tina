import 'package:classification/observation.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public result decoding preserves learned labels, Git intent and uncertainty',
    () {
      final result = UtteranceClassification.fromJson({
        'intent': {
          'type': 'agentInstruction',
          'confidence': .97,
          'categoryId': 'review',
          'categoryLabel': 'Review request',
        },
        'git': {
          'commands': ['diff', 'custom-operation'],
          'unknown': false,
        },
        'learningFailed': true,
      });
      expect(
        result.label,
        'Review request · git: diff, custom-operation · learning unavailable',
      );
      expect(result.intent.categoryId, 'review');
      expect(result.intent.confidence, .97);
      expect(() => result.git!.commands.clear(), throwsUnsupportedError);
      final uncertain = UtteranceClassification.fromJson({
        'intent': {'type': 'unclear', 'confidence': 0},
        'git': {'commands': [], 'unknown': true},
      });
      expect(uncertain.label, 'unclear · git: unclear');
      final neither = UtteranceClassification.fromJson({
        'intent': {'type': null, 'confidence': 1},
      });
      expect(neither.label, 'neither question nor instruction');
    },
  );
}
