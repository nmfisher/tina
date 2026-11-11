import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_capability/tina_capability.dart';

/// The parity table (testdata/parity-scenarios.json): this runner asserts
/// the compiler + reference-evaluator column of every row - the same
/// bytes the wasm.dart host runs its own column against.
void main() {
  final table = jsonDecode(
    File('testdata/parity-scenarios.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final rows = (table['rows'] as List).cast<Map<String, Object?>>();

  CapabilityDocument compile(Map<String, Object?> row,
      {List<CommandRuleInput> extraRules = const []}) {
    return compileCapabilities(CapabilityInputs(
      mode: CapabilityMode.parse(row['mode'] as String),
      workspace: '/ws',
      configDir: '/cfg',
      readDirectories: (row['read'] as List?)?.cast<String>() ?? const [],
      writeDirectories: (row['write'] as List?)?.cast<String>() ?? const [],
      rules: [
        for (final rule in (row['rules'] as List?) ?? const [])
          CommandRuleInput(
            pattern: rule['pattern'] as String,
            verdict: CommandVerdict.parse(rule['verdict'] as String),
            origin: rule['origin'] as String,
          ),
        ...extraRules,
      ],
      domains: [
        for (final domain in (row['domains'] as List?) ?? const [])
          DomainEntry(
            domain: domain['domain'] as String,
            origin: domain['origin'] as String,
          ),
      ],
    ));
  }

  for (final row in rows) {
    final id = row['id'] as String;
    test('parity row: $id', () {
      final operation = row['operation'] as Map<String, Object?>;
      final expect_ = row['expect'] as Map<String, Object?>;
      switch (operation['kind']) {
        case 'guest-write':
          final document = compile(row);
          // The structural wall: a guest path is writable only when a
          // preopen covers it (relative paths under `.`/named preopens,
          // absolute paths under absolutely-named preopens) and the
          // covering preopen opened rw.
          final path = operation['guest-path'] as String;
          final covering = resolveGuestPath(document.preopens, path);
          final expected = expect_['host-verdict'];
          if (expected == 'deny-structural') {
            expect(
              covering == null || covering.access == DirAccessKind.read,
              isTrue,
              reason: '$id: the guest cannot write there',
            );
          } else {
            expect(covering?.access, DirAccessKind.write,
                reason: '$id: an rw preopen covers the write');
          }
        case 'domain':
          final document = compile(row);
          final allowed = domainAllowed(
            document,
            operation['scheme'] as String,
            operation['host'] as String,
            operation['port'] as int,
          );
          expect(allowed, expect_['host-verdict'] == 'allow',
              reason: '$id: the host domain verdict');
        case 'command':
          final escalation = row['escalation'] as Map<String, Object?>?;
          if (escalation != null) {
            // An approved escalation (an "always" answer) persists the
            // grant; the next compile carries it and the widened rule
            // decides. The host's widen appends, never overrides.
            final widened = compile(row, extraRules: [
              CommandRuleInput(
                pattern: escalation['pattern'] as String,
                verdict: CommandVerdict.parse(escalation['verdict'] as String),
                origin: escalation['persist'] == true
                    ? 'grant:cargo-always-1'
                    : 'escalation',
              ),
            ]);
            final decision = evaluateCommand(
                widened, operation['command-line'] as String);
            expect(decision.verdict.json, expect_['host-verdict'] == 'allow-after-widen' ? 'allow' : 'ask',
                reason: '$id: after an approved escalation');
            if (expect_['persisted-origin'] != null) {
              expect(widened.rules.last.origin, expect_['persisted-origin'],
                  reason: '$id: the persisted grant keeps its traceable origin');
            }
          } else if (row['escalation-denied'] == true) {
            // A denied escalation widens nothing: the next call asks again.
            final document = compile(row);
            final decision =
                evaluateCommand(document, operation['command-line'] as String);
            expect(decision.verdict.json, 'ask',
                reason: '$id: a denied escalation changes nothing');
          } else {
            final document = compile(row);
            final decision =
                evaluateCommand(document, operation['command-line'] as String);
            final expected = expect_['host-verdict'];
            expect(
              decision.verdict.json,
              expected == 'allow' ? 'allow' : (expected == 'deny' ? 'deny' : 'ask'),
              reason: '$id: the host command verdict',
            );
            if (expect_['reason-fragment'] != null) {
              expect(decision.reason, contains(expect_['reason-fragment']),
                  reason: '$id: the reason contract');
            }
          }
      }
    });
  }
}

extension<T> on Iterable<T> {
  T? get singleOrNull => length == 0 ? null : first;
}

/// The preopen covering a guest path, mirroring the host's resolution:
/// relative paths resolve under `.` (or a matching named preopen),
/// absolute paths only under absolutely-named preopens, `..` refused.
PreopenEntry? resolveGuestPath(List<PreopenEntry> preopens, String path) {
  if (path.contains('..')) return null;
  if (!path.startsWith('/')) {
    for (final entry in preopens) {
      if (entry.guest.startsWith('/')) continue;
      if (entry.guest == '.') return entry;
      if (path == entry.guest || path.startsWith('${entry.guest}/')) {
        return entry;
      }
    }
    return null;
  }
  for (final entry in preopens) {
    if (entry.guest.startsWith('/') && path.startsWith(entry.guest)) {
      return entry;
    }
  }
  return null;
}

