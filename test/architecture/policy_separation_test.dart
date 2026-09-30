import 'dart:io';
import 'dart:isolate';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

Iterable<AstNode> nodes(AstNode node) sync* {
  yield node;
  for (final child in node.childEntities.whereType<AstNode>())
    yield* nodes(child);
}

void main() {
  test(
    'core, loop and host do not own feature schemas or a step ceiling',
    () async {
      const forbidden = {
        'PlanApproval',
        'PlanEntryItem',
        'PlanChangedEntry',
        'SessionPlan',
        'GoalVerdict',
        'GoalChangedEntry',
        'SessionGoal',
        'WorkflowRunEntry',
        'SessionWorkflowRun',
        'ModeChangedEntry',
        'PermissionMode',
        'ModeControl',
        'maxStepsPerTurn',
      };
      for (final package in ['tina_core', 'tina_engine_2', 'tina_host']) {
        final entry = (await Isolate.resolvePackageUri(
          Uri.parse('package:$package/$package.dart'),
        ))!;
        for (final file
            in Directory.fromUri(entry.resolve('.'))
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart'))) {
          final unit = parseString(content: file.readAsStringSync()).unit;
          final names = nodes(
            unit,
          ).whereType<SimpleIdentifier>().map((n) => n.name);
          expect(
            names.toSet().intersection(forbidden),
            isEmpty,
            reason: file.path,
          );
        }
      }
    },
  );

  test(
    'selection validation has no concrete first-party plugin ID lists',
    () async {
      final uri = (await Isolate.resolvePackageUri(
        Uri.parse('package:tina_tui/src/plugin_settings.dart'),
      ))!;
      final unit = parseString(
        content: File.fromUri(uri).readAsStringSync(),
      ).unit;
      final ids = nodes(unit)
          .whereType<SimpleStringLiteral>()
          .map((s) => s.value)
          .where((s) => RegExp(r'^tina/[a-z]').hasMatch(s));
      expect(ids, isEmpty);
    },
  );
}
