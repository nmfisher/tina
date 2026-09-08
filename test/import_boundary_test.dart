import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/architecture/policy.dart';

void main() {
  test(
    'owned sources and manifests obey architecture policy and exact baseline',
    () async {
      // Other suites change cwd; package resolution is independent of that state.
      final uri = await Isolate.resolvePackageUri(
        Uri.parse('package:tina/config/runtime_config.dart'),
      );
      final root = p.dirname(p.dirname(p.dirname(uri!.toFilePath())));
      final policy = ArchitecturePolicy.read(
        p.join(root, 'tool/architecture/policy.json'),
      );
      final result = checkWorkspace(root, policy);
      final baseline =
          jsonDecode(
                File(
                  p.join(
                    root,
                    'tool/architecture',
                    policy.data['baseline'] as String,
                  ),
                ).readAsStringSync(),
              )
              as List;
      expect(applyBaseline(result.violations, baseline), isEmpty);
      expect(result.files, greaterThan(0));
    },
  );
}
