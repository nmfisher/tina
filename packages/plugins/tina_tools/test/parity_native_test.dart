import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_capability/tina_capability.dart';
import 'package:tina_mode/tina_mode.dart'
    show
        AccessCapability,
        AccessRequirement,
        AuthorizationRequest,
        AuthorizationRoute,
        PermissionMode,
        resolveAuthorization;

/// The native column of the parity table (testdata/parity-scenarios.json,
/// the same bytes the wasm.dart host runs): the mode table's route for
/// each workspace-write row must equal the expectation the host asserts
/// against its structural wall on its side.
PermissionMode _mode(String json) => switch (json) {
      'ask' => PermissionMode.ask,
      'read-only' => PermissionMode.readOnly,
      'allow-edits' => PermissionMode.allowEdits,
      'auto' => PermissionMode.auto,
      'yolo' => PermissionMode.yolo,
      final other => throw ArgumentError('unknown mode $other'),
    };

void main() {
  final table = jsonDecode(
    File(p.join('testdata', 'parity-scenarios.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final rows = (table['rows'] as List)
      .cast<Map<String, Object?>>()
      .where((row) =>
          (row['operation'] as Map<String, Object?>)['kind'] == 'guest-write')
      .toList();

  for (final row in rows) {
    final id = row['id'] as String;
    test('native route parity: $id', () {
      final expect_ = row['expect'] as Map<String, Object?>;
      final outside =
          ((row['operation'] as Map<String, Object?>)['guest-path'] as String)
          .startsWith('/');
      final request = AuthorizationRequest(
        requirements: [
          AccessRequirement(
            AccessCapability.write,
            outside
                ? '/etc/outside.txt'
                : p.join('workspace', 'file.txt'),
            workspace: !outside,
          ),
        ],
        confined: true,
      );
      final resolution =
          resolveAuthorization(request, _mode(row['mode'] as String));
      final expectedRoute = switch (expect_['route']) {
        'allow' => AuthorizationRoute.allow,
        'deny' => AuthorizationRoute.deny,
        _ => AuthorizationRoute.human,
      };
      expect(resolution.route, expectedRoute,
          reason: '$id: the mode table route on native');
    });
  }
}
