import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  test(
    'review records restore provenance and cannot mutate nested configuration',
    () {
      final options = <String, Object?>{
        'labels': ['yes', 'no'],
      };
      final record = RuleRecord(
        RuleProposal(
          RuleConfig(
            id: 'example',
            implementation: 'plugin.example',
            revision: 2,
            instruction: const InstructionRef(
              'file:///project/AGENTS.md',
              'revision',
            ),
            trigger: RuleTrigger.tool,
            options: options,
          ),
          'A proposed check',
        ),
        RuleState.dismissed,
      );
      (options['labels'] as List).clear();
      final restored = RuleRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>,
      );
      expect(restored.state, RuleState.dismissed);
      expect(restored.proposal.rule.options['labels'], ['yes', 'no']);
      expect(
        () => (restored.proposal.rule.options['labels'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(restored.proposal.rule.instruction.revision, 'revision');
      expect(restored.proposal.rule.revision, 2);
      expect(restored.proposal.rule.trigger, RuleTrigger.tool);
      expect(
        () => RuleRecord.fromJson({...record.toJson(), 'version': 2}),
        throwsFormatException,
      );
    },
  );
}
