import 'dart:convert';
import 'dart:io';
import 'package:tina_repository_tools/repository.dart';
import 'package:tina_repository_tools/src/architecture/policy.dart';

Future<void> main(List<String> args) async {
  final root = (await repositoryRoot()).path;
  try {
    final policy = ArchitecturePolicy.read('$root/tool/repository/policy.json');
    final check = checkWorkspace(root, policy);
    final violations = check.violations;
    if (args.contains('--report')) {
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(violations.map((v) => v.toJson()).toList()),
      );
      return;
    }
    final baseline =
        jsonDecode(
              File(
                '$root/tool/repository/${policy.data['baseline']}',
              ).readAsStringSync(),
            )
            as List;
    final errors = applyBaseline(violations, baseline);
    if (errors.isNotEmpty) {
      stderr.writeln(errors.join('\n\n'));
      exitCode = 1;
    } else {
      stdout.writeln(
        'Architecture checks passed (${check.files} owned files; ${baseline.length} exact exceptions).',
      );
    }
  } catch (e) {
    stderr.writeln('Architecture check failed: $e');
    exitCode = 1;
  }
}
