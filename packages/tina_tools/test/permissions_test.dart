import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

/// Headless tests for the permission rules (`src/permissions.dart`).
///
/// Pure calls only — no filesystem, no process, no terminal: the policy is
/// a function from capabilities × mode to a verdict, so the tests are too.
void main() {
  // The shipped tools' declarations, reused for the shipped-tool rows.
  const readsTool = ToolCapabilities(); // read, ls, glob, stat
  const writeTool = ToolCapabilities(writes: WriteScope.project); // write, edit
  // A control-plane tool: it touches nothing on the machine itself.
  const touchesNothing = ToolCapabilities(reads: ReadScope.none);
  const undeclared = ToolCapabilities.undeclared;

  // One axis set to the scope under test, everything else at its harmless
  // default — the unit of "every scope against both modes".
  ToolCapabilities axis(String name, Enum scope) => switch ((name, scope)) {
        ('reads', final ReadScope s) => ToolCapabilities(reads: s),
        ('writes', final WriteScope s) => ToolCapabilities(writes: s),
        ('spawns', final SpawnScope s) => ToolCapabilities(spawns: s),
        ('network', final NetworkScope s) => ToolCapabilities(network: s),
        ('indirect', final IndirectWork s) => ToolCapabilities(indirect: s),
        _ => throw ArgumentError('($name, $scope)'),
      };

  /// The rule table: each scope under both modes. Reads allow; a project or
  /// sidecar write asks in normal and denies in readOnly (a host write is a
  /// sandbox escape, so at best an ask); model argv and egress like a
  /// process; fixed argv is fully pinned, so it runs; indirect work follows
  /// the profile of the agents it can start.
  const table = <(String, Enum, ToolVerdict, ToolVerdict)>[
    ('reads', ReadScope.none, ToolVerdict.ask, ToolVerdict.deny),
    ('reads', ReadScope.project, ToolVerdict.allow, ToolVerdict.allow),
    ('reads', ReadScope.host, ToolVerdict.ask, ToolVerdict.deny),
    ('writes', WriteScope.none, ToolVerdict.allow, ToolVerdict.allow),
    ('writes', WriteScope.project, ToolVerdict.ask, ToolVerdict.deny),
    ('writes', WriteScope.sidecar, ToolVerdict.ask, ToolVerdict.deny),
    ('writes', WriteScope.host, ToolVerdict.ask, ToolVerdict.deny),
    ('spawns', SpawnScope.none, ToolVerdict.allow, ToolVerdict.allow),
    ('spawns', SpawnScope.fixed, ToolVerdict.allow, ToolVerdict.allow),
    ('spawns', SpawnScope.modelArgv, ToolVerdict.ask, ToolVerdict.deny),
    ('network', NetworkScope.none, ToolVerdict.allow, ToolVerdict.allow),
    ('network', NetworkScope.egress, ToolVerdict.ask, ToolVerdict.deny),
    ('indirect', IndirectWork.none, ToolVerdict.allow, ToolVerdict.allow),
    ('indirect', IndirectWork.readOnlyOnly, ToolVerdict.allow, ToolVerdict.allow),
    ('indirect', IndirectWork.anyProfile, ToolVerdict.ask, ToolVerdict.deny),
  ];

  group('every scope against both modes', () {
    for (final (axisName, scope, normal, readOnly) in table) {
      test('$axisName=${scope.name}: normal → ${normal.name}', () {
        expect(
          check((capabilities: axis(axisName, scope), mode: PermissionMode.normal)),
          normal,
        );
      });
      test('$axisName=${scope.name}: readOnly → ${readOnly.name}', () {
        expect(
          check((capabilities: axis(axisName, scope), mode: PermissionMode.readOnly)),
          readOnly,
        );
      });
    }
  });

  group('the shipped tools', () {
    test('read/ls/glob/stat run in both modes', () {
      for (final mode in PermissionMode.values) {
        expect(
          check((capabilities: readsTool, mode: mode)),
          ToolVerdict.allow,
        );
      }
    });

    test('write/edit ask in normal and deny in readOnly', () {
      expect(
        check((capabilities: writeTool, mode: PermissionMode.normal)),
        ToolVerdict.ask,
      );
      expect(
        check((capabilities: writeTool, mode: PermissionMode.readOnly)),
        ToolVerdict.deny,
      );
    });
  });

  group('combinations', () {
    test('read + project write: the write decides', () {
      const caps = ToolCapabilities(
        reads: ReadScope.project,
        writes: WriteScope.project,
      );
      expect(
        check((capabilities: caps, mode: PermissionMode.normal)),
        ToolVerdict.ask,
      );
      expect(
        check((capabilities: caps, mode: PermissionMode.readOnly)),
        ToolVerdict.deny,
      );
    });

    test('fixed argv + egress: the escape decides', () {
      const caps = ToolCapabilities(
        spawns: SpawnScope.fixed,
        network: NetworkScope.egress,
      );
      expect(
        check((capabilities: caps, mode: PermissionMode.normal)),
        ToolVerdict.ask,
      );
      expect(
        check((capabilities: caps, mode: PermissionMode.readOnly)),
        ToolVerdict.deny,
      );
    });

    test('read-only agents under a read-only run are still fine', () {
      const caps = ToolCapabilities(indirect: IndirectWork.readOnlyOnly);
      for (final mode in PermissionMode.values) {
        expect(check((capabilities: caps, mode: mode)), ToolVerdict.allow);
      }
    });
  });

  group('undeclared capabilities fail closed', () {
    test('never allowed in any mode', () {
      for (final mode in PermissionMode.values) {
        expect(
          check((capabilities: undeclared, mode: mode)),
          isNot(ToolVerdict.allow),
        );
      }
    });

    test('normal asks — the worst case is a question, not a pass', () {
      expect(
        check((capabilities: undeclared, mode: PermissionMode.normal)),
        ToolVerdict.ask,
      );
    });

    test('readOnly denies without a prompt', () {
      expect(
        check((capabilities: undeclared, mode: PermissionMode.readOnly)),
        ToolVerdict.deny,
      );
    });
  });

  group('a tool that touches nothing', () {
    test('asks in normal — starting other work is the user’s decision', () {
      expect(
        check((capabilities: touchesNothing, mode: PermissionMode.normal)),
        ToolVerdict.ask,
      );
    });

    test('denies in readOnly', () {
      expect(
        check((capabilities: touchesNothing, mode: PermissionMode.readOnly)),
        ToolVerdict.deny,
      );
    });

    test('the reason says why it is not an allow', () {
      expect(
        reasonFor(ToolVerdict.ask, touchesNothing),
        contains('starting it is your decision'),
      );
    });
  });

  group('sandbox escape is never silently allowed', () {
    final escapers = <(String, ToolCapabilities)>[
      ('model argv', const ToolCapabilities(spawns: SpawnScope.modelArgv)),
      (
        'reviewed model argv',
        ToolCapabilities(
          spawns: SpawnScope.modelArgv,
          reviewed: 'reviewed in the security pass',
        ),
      ),
      ('egress', const ToolCapabilities(network: NetworkScope.egress)),
      (
        'reviewed egress',
        ToolCapabilities(
          network: NetworkScope.egress,
          reviewed: 'reviewed in the security pass',
        ),
      ),
      ('host write', const ToolCapabilities(writes: WriteScope.host)),
      ('host read', const ToolCapabilities(reads: ReadScope.host)),
      ('undeclared', undeclared),
    ];

    for (final (name, caps) in escapers) {
      test('$name: no mode allows it', () {
        for (final mode in PermissionMode.values) {
          expect(
            check((capabilities: caps, mode: mode)),
            isNot(ToolVerdict.allow),
            reason: '$name under $mode',
          );
        }
      });
    }

    test('even a reviewed justification only buys an ask in normal', () {
      final caps = ToolCapabilities(
        spawns: SpawnScope.modelArgv,
        reviewed: 'reviewed in the security pass',
      );
      expect(caps.escapesTheSandbox, isTrue);
      expect(
        check((capabilities: caps, mode: PermissionMode.normal)),
        ToolVerdict.ask,
      );
    });

    test('an escape reason names the escape and any justification', () {
      expect(
        reasonFor(ToolVerdict.ask, const ToolCapabilities(reads: ReadScope.host)),
        contains('escapes the sandbox'),
      );
      final reviewed = ToolCapabilities(
        spawns: SpawnScope.modelArgv,
        reviewed: 'reviewed in the security pass',
      );
      expect(reasonFor(ToolVerdict.ask, reviewed), contains('reviewed'));
    });
  });

  group('read-only mode never asks', () {
    test('every askable capability set downgrades to deny', () {
      final askables = [
        writeTool,
        const ToolCapabilities(writes: WriteScope.sidecar),
        const ToolCapabilities(writes: WriteScope.host),
        const ToolCapabilities(spawns: SpawnScope.modelArgv),
        const ToolCapabilities(network: NetworkScope.egress),
        const ToolCapabilities(reads: ReadScope.host),
        const ToolCapabilities(indirect: IndirectWork.anyProfile),
        touchesNothing,
        undeclared,
      ];
      for (final caps in askables) {
        expect(
          check((capabilities: caps, mode: PermissionMode.readOnly)),
          ToolVerdict.deny,
          reason: '$caps',
        );
      }
    });

    test('a readOnly deny reason says the mode forbids it', () {
      final r = checkWithReason(
        (capabilities: writeTool, mode: PermissionMode.readOnly),
      );
      expect(r.verdict, ToolVerdict.deny);
      expect(r.reason, contains('read-only'));
    });
  });

  group('reasons', () {
    test('an allow says why it needed no approval', () {
      final r = checkWithReason(
        (capabilities: readsTool, mode: PermissionMode.normal),
      );
      expect(r.verdict, ToolVerdict.allow);
      expect(r.reason, contains('read-only'));
    });

    test('model argv names who chose the arguments', () {
      expect(
        reasonFor(
          ToolVerdict.ask,
          const ToolCapabilities(spawns: SpawnScope.modelArgv),
        ),
        contains('arguments the model chose'),
      );
    });

    test('egress names the network', () {
      expect(
        reasonFor(
          ToolVerdict.ask,
          const ToolCapabilities(network: NetworkScope.egress),
        ),
        contains('network'),
      );
    });

    test('indirect work names other agents', () {
      expect(
        reasonFor(
          ToolVerdict.ask,
          const ToolCapabilities(indirect: IndirectWork.anyProfile),
        ),
        contains('other agents'),
      );
    });

    test('a host read names the host', () {
      expect(
        reasonFor(
          ToolVerdict.ask,
          const ToolCapabilities(reads: ReadScope.host),
        ),
        contains('host'),
      );
    });

    test('a readOnly deny of a machine-touching tool says so', () {
      // writeTool does not escape the sandbox (it writes inside the project),
      // but it still needs execution, so read-only refuses it outright.
      expect(
        reasonFor(ToolVerdict.deny, writeTool),
        contains('needs execution'),
      );
    });
  });

  group('the policy is a pure function', () {
    test('same input, same verdict, no state carried between calls', () {
      const caps = ToolCapabilities(writes: WriteScope.project);
      final a = check((capabilities: caps, mode: PermissionMode.normal));
      final b = check((capabilities: caps, mode: PermissionMode.normal));
      final c = check((capabilities: caps, mode: PermissionMode.readOnly));
      expect(a, b);
      expect(a, isNot(c));
    });

    test('checkWithReason agrees with check', () {
      const caps = ToolCapabilities(spawns: SpawnScope.modelArgv);
      for (final mode in PermissionMode.values) {
        final r = checkWithReason((capabilities: caps, mode: mode));
        expect(r.verdict, check((capabilities: caps, mode: mode)));
        expect(r.reason, isNotEmpty);
      }
    });
  });
}
