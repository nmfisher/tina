/// Parity tests for the process access profile: every case here mirrors
/// a unit test of the Rust host's evaluator (wasm.dart,
/// `pkg/test_runner/src/tina_process.rs`), because the reason strings
/// are interface contract - the native port and the wasm host must
/// refuse and ask with the same words.
library;

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

void main() {
  test('first anchored match decides', () {
    final profile = ProcessAccessProfile([
      ProcessRule('git status', ProcessVerdict.allow),
      ProcessRule('rm .*', ProcessVerdict.deny),
    ]);
    expect(
      evaluateProcessPolicy(profile, 'git status').verdict,
      ProcessVerdict.allow,
    );
    // Anchoring: the allow rule does not cover extra arguments, and a
    // later deny rule does not override an earlier non-match.
    expect(
      evaluateProcessPolicy(profile, 'git status --porcelain').reason,
      'no rule matched the command',
    );
    expect(
      evaluateProcessPolicy(profile, 'git rm -rf /').reason,
      'no rule matched the command',
    );
    expect(
      evaluateProcessPolicy(profile, 'rm -rf /tmp/probe-deny').reason,
      'rule 1 (rm .*) denies the command',
    );
  });

  test('no match asks', () {
    final decision = evaluateProcessPolicy(
      const ProcessAccessProfile([]),
      'printf hi',
    );
    expect(decision.verdict, ProcessVerdict.ask);
    expect(decision.reason, 'no rule matched the command');
  });

  test('invalid patterns fail closed', () {
    final decision = evaluateProcessPolicy(
      ProcessAccessProfile([
        ProcessRule('[unclosed', ProcessVerdict.allow),
      ]),
      'anything',
    );
    expect(decision.verdict, ProcessVerdict.deny);
    expect(decision.reason, 'rule 0 ([unclosed) is not a valid pattern');
  });

  test('ask reasons are the contract', () {
    final decision = evaluateProcessPolicy(
      ProcessAccessProfile([ProcessRule('cargo .*', ProcessVerdict.ask)]),
      'cargo build',
    );
    expect(decision.reason, 'rule 0 (cargo .*) requires approval');
  });
}
