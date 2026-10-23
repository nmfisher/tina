import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

/// The operation × mode table (`decideOperation`) and the session grants,
/// headless: the table is pure — strings in, verdict out.
///
/// The table, as built:
///
/// | op    | mode     | in project root | outside root / `~/.tina` |
/// |-------|----------|-----------------|--------------------------|
/// | read  | normal   | allow           | allow                    |
/// | read  | readOnly | allow           | allow                    |
/// | write | normal   | allow           | ask (deny if refused / no approver) |
/// | write | readOnly | ask               | ask                    |
void main() {
  const root = '/work/project';

  test(
      'writes in ask and auto require review; only allow-edits permits project writes',
      () {
    const selectable = [
      PermissionMode.ask,
      PermissionMode.readOnly,
      PermissionMode.allowEdits,
      PermissionMode.auto,
    ];
    for (final mode in selectable) {
      final result = decideOperation(
          (op: FileOp.write, path: '$root/file'), mode,
          projectRoot: root);
      expect(
          result.verdict,
          switch (mode) {
            PermissionMode.allowEdits => ToolVerdict.allow,
            PermissionMode.readOnly => ToolVerdict.deny,
            _ => ToolVerdict.ask,
          });
    }
  });

  group('table: read', () {
    test('inside the project, both modes → allow', () {
      for (final mode in PermissionMode.values) {
        final d = decideOperation(
          (op: FileOp.read, path: '$root/lib/main.dart'),
          mode,
          projectRoot: root,
        );
        expect(d.verdict, ToolVerdict.allow, reason: '$mode');
      }
    });

    test('external reads require approval in ordinary modes', () {
      // The new posture: reads anywhere the process can reach are allowed.
      // Only the Tina data tree is off-limits to reads, and that refusal
      // stays a structural throw in the filesystem, not a table row.
      for (final path in ['/etc/passwd', '/home/nick/.bashrc']) {
        for (final mode in PermissionMode.values) {
          final d = decideOperation(
            (op: FileOp.read, path: path),
            mode,
            projectRoot: root,
          );
          expect(d.verdict,
              mode == PermissionMode.yolo ? ToolVerdict.allow : ToolVerdict.ask,
              reason: '$path under $mode');
        }
      }
    });
  });

  group('table: write', () {
    test('inside the project in allow-edits → allow', () {
      final d = decideOperation(
        (op: FileOp.write, path: '$root/lib/main.dart'),
        PermissionMode.allowEdits,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.allow);
      expect(d.reason, contains('inside the project root'));
    });

    test('inside the project in readOnly → deny', () {
      final d = decideOperation(
        (op: FileOp.write, path: '$root/lib/main.dart'),
        PermissionMode.readOnly,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.deny);
      expect(d.reason, contains('read-only mode'));
    });

    test('outside the project in ask → ask', () {
      final d = decideOperation(
        (op: FileOp.write, path: '/etc/hosts'),
        PermissionMode.ask,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.ask);
      expect(d.reason, contains('outside the project root'));
      expect(d.reason, contains('hosts')); // the leaf, never a resolved tree
    });

    test('outside the project in readOnly → deny', () {
      final d = decideOperation(
        (op: FileOp.write, path: '/etc/hosts'),
        PermissionMode.readOnly,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.deny);
    });

    test('a path that merely shares a prefix is not "inside"', () {
      final d = decideOperation(
        (op: FileOp.write, path: '${root}-sibling/file'),
        PermissionMode.ask,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.ask);
    });

    test('the root itself counts as inside', () {
      final d = decideOperation(
        (op: FileOp.write, path: root),
        PermissionMode.allowEdits,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.allow);
    });
  });

  group('yolo', () {
    test('allows every read and write, in and out of the project', () {
      for (final path in ['$root/file', '$root/lib/main.dart', '/etc/hosts']) {
        for (final op in FileOp.values) {
          final d = decideOperation(
            (op: op, path: path),
            PermissionMode.yolo,
            projectRoot: root,
          );
          expect(d.verdict, ToolVerdict.allow, reason: '${op.name} $path');
          expect(d.reason, contains('yolo'));
        }
      }
    });

    test('allows writes even outside the project root', () {
      final d = decideOperation(
        (op: FileOp.write, path: '/etc/hosts'),
        PermissionMode.yolo,
        projectRoot: root,
      );
      expect(d.verdict, ToolVerdict.allow);
    });
  });

  group('session grants (the "always" answer)', () {
    test('an exact remembered path allows that write without asking', () {
      final grants = FileGrants()..remember('/etc/hosts');
      final d = decideOperation(
        (op: FileOp.write, path: '/etc/hosts'),
        PermissionMode.ask,
        projectRoot: root,
        grants: grants,
      );
      expect(d.verdict, ToolVerdict.allow);
      expect(d.reason, contains('session grant'));
    });

    test('a remembered glob allows everything it matches, nothing wider', () {
      final grants = FileGrants()..remember('/tmp/shared/**');
      bool allows(String path) =>
          decideOperation(
            (op: FileOp.write, path: path),
            PermissionMode.ask,
            projectRoot: root,
            grants: grants,
          ).verdict ==
          ToolVerdict.allow;
      expect(allows('/tmp/shared/a.txt'), isTrue);
      expect(allows('/tmp/shared/deep/b.txt'), isTrue);
      expect(allows('/tmp/other.txt'), isFalse);
    });

    test('read-only overrides a remembered write grant', () {
      final grants = FileGrants()..remember('/etc/hosts');
      final d = decideOperation(
        (op: FileOp.write, path: '/etc/hosts'),
        PermissionMode.readOnly,
        projectRoot: root,
        grants: grants,
      );
      expect(d.verdict, ToolVerdict.deny);
    });

    test('remembering twice is idempotent; patterns list oldest first', () {
      final grants = FileGrants();
      expect(grants.isEmpty, isTrue);
      expect(grants.remember('/a'), isTrue);
      expect(grants.remember('/a'), isFalse);
      expect(grants.remember('/b'), isTrue);
      expect(grants.patterns, ['/a', '/b']);
      expect(grants.length, 2);
      expect(grants.patternFor('/b'), '/b');
      expect(grants.patternFor('/c'), isNull);
      expect(grants.allows('/a/deeper'), isFalse);
      expect(grants.allows('/sibling-of-a'), isFalse);
    });
  });

  group('reasons are model-readable', () {
    test('an ask names the operation and the leaf, not a resolved tree', () {
      final d = decideOperation(
        (op: FileOp.write, path: '/home/nick/.ssh/config'),
        PermissionMode.ask,
        projectRoot: root,
      );
      expect(d.reason, contains('config'));
      expect(d.reason, contains('outside the project root'));
    });

    test('read-only denial explains that changing mode is required', () {
      final d = decideOperation(
        (op: FileOp.write, path: '$root/notes.md'),
        PermissionMode.readOnly,
        projectRoot: root,
      );
      expect(d.reason, contains('read-only mode blocks'));
    });
  });
}
