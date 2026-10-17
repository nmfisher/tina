import 'dart:io';

import 'package:classification/permissions.dart';
import 'package:test/test.dart';

const scope = PrecedentScope(
  workspace: '/work/project',
  readDirectories: ['/data/shared'],
);

RequestSignature command(
  List<String> arguments, {
  String program = 'git',
  String tool = 'exec',
  List<String> permissions = const ['execution'],
}) =>
    RequestSignature.of(
      {
        'operation': 'run command',
        'tool': {'name': tool},
        'executable': program,
        'arguments': arguments,
        'required_permissions': permissions,
      },
      scope: scope,
    )!;

ApprovalPrecedent precedent(
  RequestSignature signature, {
  PrecedentOutcome outcome = PrecedentOutcome.allow,
  PrecedentAuthority authority = PrecedentAuthority.humanOnce,
  int count = 1,
  String coverage = 'complete',
  bool conflicted = false,
  DateTime? lastSeen,
}) =>
    ApprovalPrecedent(
      signature: signature,
      outcome: outcome,
      authority: authority,
      count: count,
      lastSeen: lastSeen ?? DateTime.utc(2026, 10, 1),
      coverage: coverage,
      conflicted: conflicted,
    );

void main() {
  group('signature normalization', () {
    test('flag forms collapse to one shape', () {
      expect(command(['log', '-n', '2']).flags, ['-n#']);
      expect(command(['log', '-n2']).flags, ['-n#']);
      expect(command(['log', '--lines=2']).flags, ['--lines=#']);
      expect(command(['log', '--oneline']).flags, ['--oneline']);
    });

    test('operands keep only classes, never text', () {
      final signature = command(['log', '--oneline', 'notes.md']);
      expect(signature.operands, ['path:workspace']);
      expect(signature.pathClasses, {'workspace'});
      expect(signature.key, isNot(contains('notes')));
    });

    test('paths classify against the workspace and granted directories', () {
      expect(command(['diff', 'lib/a.dart']).operands, ['path:workspace']);
      expect(command(['cat', '/data/shared/x']).operands, ['path:granted']);
      expect(command(['cat', '/etc/shadow']).operands, ['path:outside']);
    });

    test('secret-looking arguments are reduced, not stored', () {
      expect(command(['log', 'GITHUB_TOKEN'.toLowerCase()]).operands, ['word']);
      expect(command(['log', '--token=abcdefabcdefabcdefabcdefabcdef']).flags,
          ['--token=value']);
      expect(
          command(['log', 'sk-abcdefghijklmnopqrstuvwxyz012345']).operands,
          ['secret']);
    });

    test('subcommand is the first bare word, flags following it stay flags', () {
      final signature = command(['log', '--oneline', 'main']);
      expect(signature.subcommand, 'log');
      expect(signature.flags, ['--oneline']);
      expect(signature.operands, ['word']);
    });

    test('file requests take the operation as the program', () {
      final signature = RequestSignature.of(
        {
          'operation': 'write',
          'target': '/work/project/out.txt',
          'tool': {'name': 'write'},
        },
        scope: scope,
      )!;
      expect(signature.program, 'write');
      expect(signature.operands, ['path:workspace']);
    });

    test('a request with no recognizable shape has no signature', () {
      expect(RequestSignature.of({'operation': ''}, scope: scope), isNull);
    });
  });

  group('similarity', () {
    test('the same shape scores 1', () {
      expect(similarity(command(['log', '--oneline']),
          command(['log', '--oneline'])), closeTo(1, 1e-9));
    });

    test('a different operand class still scores high', () {
      expect(
          similarity(
              command(['log', 'notes.md']), command(['log', 'lib/a.dart'])),
          greaterThan(0.8));
    });

    test('a different program never matches', () {
      expect(similarity(command(['log']), command(['log'], program: 'ls')), 0);
    });

    test('a different subcommand never matches', () {
      expect(similarity(command(['log']), command(['push'])), 0);
    });

    test('a same-program operand swap stays eligible', () {
      expect(
          similarity(
              command(['log', '--limit', '1']), command(['log', '--limit', '20'])),
          greaterThan(0.9));
    });
  });

  group('evidence eligibility', () {
    test('a confined precedent never covers a network request', () {
      final request = command(['log'], permissions: ['execution', 'network']);
      expect(usableAsEvidence(precedent(command(['log'])), request), false);
    });

    test('a network precedent can cover a confined request', () {
      final network = command(['log'], permissions: ['execution', 'network']);
      expect(usableAsEvidence(precedent(network), command(['log'])), true);
    });

    test('a conflicted precedent is never evidence', () {
      expect(
          usableAsEvidence(
              precedent(command(['log']), conflicted: true),
              command(['log'])),
          false);
    });

    test('ranking is capped, deduplicated and puts denials first on ties', () {
      final request = command(['log', '--oneline']);
      final ranked = rankPrecedents(request, [
        precedent(command(['log', '--oneline'])),
        precedent(command(['log', '--oneline']),
            outcome: PrecedentOutcome.deny),
        for (var i = 0; i < 8; i++) precedent(command(['log', '--oneline'])),
      ]);
      expect(ranked, hasLength(2), reason: 'one entry per outcome and key');
      expect(ranked.first.precedent.outcome, PrecedentOutcome.deny);
    });

    test('evidence carries no raw argument text', () {
      final request = command(['log', 'secret-notes.md']);
      final evidence =
          precedentEvidence(rankPrecedents(request, [precedent(request)]));
      expect(evidence.single['request'].toString(), isNot(contains('secret')));
      expect(evidence.single['request'].toString(), contains('path:workspace'));
    });
  });

  group('fast path', () {
    final readOnly = command(['log', '--oneline']);

    bool allows(Iterable<ApprovalPrecedent> precedents,
            {String coverage = 'complete', bool allRead = true}) =>
        allowsWithoutJudgment(
          request: readOnly,
          precedents: precedents,
          coverage: coverage,
          allAccessesRead: allRead,
        );

    test('two prior approvals make the third quiet', () {
      expect(allows([precedent(readOnly, count: 1)]), false);
      expect(allows([precedent(readOnly, count: 2)]), true);
    });

    test('a single denial poisons the shape forever', () {
      expect(
          allows([
            precedent(readOnly, count: 9),
            precedent(readOnly, outcome: PrecedentOutcome.deny),
          ]),
          false);
    });

    test('a conflicted shape always asks', () {
      expect(allows([precedent(readOnly, count: 4, conflicted: true)]), false);
    });

    test('partial or unknown coverage always asks', () {
      expect(allows([precedent(readOnly, count: 4)], coverage: 'partial'),
          false);
      expect(allows([precedent(readOnly, count: 4)], allRead: false), false);
    });

    test('network and unconfined requests never take the fast path', () {
      for (final permissions in [
        ['execution', 'network'],
        ['execution', 'unconfined'],
      ]) {
        final request = command(['log'], permissions: permissions);
        expect(
            allowsWithoutJudgment(
              request: request,
              precedents: [precedent(request, count: 9)],
              coverage: 'complete',
              allAccessesRead: true,
            ),
            false);
      }
    });

    test('stale approvals do not count', () {
      expect(
          allows([
            precedent(readOnly,
                count: 4, lastSeen: DateTime.utc(2025, 1, 1)),
          ]),
          false);
    });

    test('a different shape does not inherit the approvals', () {
      expect(
          allows([
            precedent(command(['push']), count: 9),
          ]),
          false);
    });
  });

  group('merging', () {
    final signature = command(['log']);

    test('repeating an outcome increments the count', () {
      final first = mergeDecision(
        null,
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        at: DateTime.utc(2026, 10, 1),
      );
      final second = mergeDecision(
        first,
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.classifier,
        at: DateTime.utc(2026, 10, 2),
      );
      expect(second.count, 2);
      expect(second.conflicted, false);
      expect(second.lastSeen, DateTime.utc(2026, 10, 2));
    });

    test('an approval after a denial becomes conflicted and keeps the denial', () {
      final denied = mergeDecision(
        null,
        signature: signature,
        outcome: PrecedentOutcome.deny,
        authority: PrecedentAuthority.humanOnce,
        at: DateTime.utc(2026, 10, 1),
      );
      final allowed = mergeDecision(
        denied,
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        at: DateTime.utc(2026, 10, 2),
      );
      expect(allowed.outcome, PrecedentOutcome.deny);
      expect(allowed.conflicted, true);
    });
  });

  group('storage', () {
    late Directory directory;
    setUp(() =>
        directory = Directory.systemTemp.createTempSync('tina-precedent-test-'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('records round-trip through the file store', () {
      final path = '${directory.path}/precedents.jsonl';
      final store = FilePrecedentStore(path);
      final signature = command(['log', '--oneline']);
      store.record(
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        coverage: 'complete',
        at: DateTime.utc(2026, 10, 1),
      );
      store.record(
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.classifier,
        coverage: 'complete',
        at: DateTime.utc(2026, 10, 2),
      );
      final restored = FilePrecedentStore(path).read().single;
      expect(restored.count, 2);
      expect(restored.signature.key, signature.key);
      expect(restored.coverage, 'complete');
    });

    test('a corrupt line is skipped, not fatal', () {
      final path = '${directory.path}/precedents.jsonl';
      final store = FilePrecedentStore(path);
      store.record(
        signature: command(['log']),
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        coverage: 'complete',
      );
      File(path).writeAsStringSync(
          '${File(path).readAsStringSync()}{not json\n', flush: true);
      expect(FilePrecedentStore(path).read(), hasLength(1));
    });

    test('the cap keeps the most recently seen signatures', () {
      final store = FilePrecedentStore('${directory.path}/capped.jsonl',
          cap: 2);
      for (var i = 0; i < 4; i++) {
        store.record(
          // Distinct subcommands: operands and flags collapse to classes, so
          // only a different operation makes a genuinely different signature.
          signature: command(['operation$i']),
          outcome: PrecedentOutcome.allow,
          authority: PrecedentAuthority.humanOnce,
          coverage: 'complete',
          at: DateTime.utc(2026, 10, 1 + i),
        );
      }
      final kept = store.read();
      expect(kept, hasLength(2));
      expect(
          kept.every((entry) => entry.lastSeen.isAfter(DateTime.utc(2026, 10, 2))),
          true);
    });

    test('workspaces do not share history', () {
      final first = FilePrecedentStore('${directory.path}/a.jsonl');
      first.record(
        signature: command(['log']),
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        coverage: 'complete',
      );
      expect(FilePrecedentStore('${directory.path}/b.jsonl').read(), isEmpty);
    });

    test('forget and clear erase history', () {
      final path = '${directory.path}/forget.jsonl';
      final store = FilePrecedentStore(path);
      final signature = command(['log']);
      store.record(
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        coverage: 'complete',
      );
      store.forget(signature.key);
      expect(store.read(), isEmpty);
      store.record(
        signature: signature,
        outcome: PrecedentOutcome.allow,
        authority: PrecedentAuthority.humanOnce,
        coverage: 'complete',
      );
      store.clear();
      expect(store.read(), isEmpty);
    });

    test('a truncated store is readable', () {
      final path = '${directory.path}/broken.jsonl';
      File(path).writeAsStringSync('{"signature":');
      expect(FilePrecedentStore(path).read(), isEmpty);
    });
  });

  group('mode parsing', () {
    test('defaults to evidence and rejects unknown words', () {
      expect(parsePrecedentMode(null), PrecedentMode.evidence);
      expect(parsePrecedentMode('nonsense'), PrecedentMode.evidence);
      expect(parsePrecedentMode('OFF'), PrecedentMode.off);
      expect(parsePrecedentMode('full'), PrecedentMode.full);
    });
  });
}
