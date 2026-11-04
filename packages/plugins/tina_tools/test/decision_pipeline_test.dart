// The decision pipeline: one precedence — envelope → scopes → sandbox
// feasibility → run, else judgment. Destructive and network effects route
// to judgment; no enforcing backend refuses, fail closed; the two fast
// paths (certified readers, agent-created scripts) run without asking.
library;

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

final class _Scopes implements ScopesView {
  const _Scopes({this.reads = const {}, this.writes = const {}, this.plan = const {}});
  final Set<String> reads;
  final Set<String> writes;
  final Set<String> plan;

  @override
  bool canRead(String path) => reads.contains(path);

  @override
  bool canWrite(String path) => writes.contains(path);

  @override
  bool withinPlan(String path) => plan.contains(path);
}

ProcessRequest _req(String command, List<String> arguments) =>
    (
      command: command,
      arguments: arguments,
      workingDirectory: '/workspace',
      environment: null,
      stdin: null,
      timeout: null,
    );

void main() {
  test('destructive verdicts route to judgment, never a silent run', () {
    final envelope = CapabilityEnvelope.parse(_req('rm', ['-rf', '/workspace']),
        searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(),
        confined: true,
        agentCreatedScript: false);
    expect(decision.needsJudgment, isTrue);
    expect(decision.reason, contains('destructive'));
  });

  test('network requests route to judgment', () {
    final envelope = CapabilityEnvelope.parse(_req('curl', ['https://x.test']),
        control: const ProcessControl(networkRequested: true),
        searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(),
        confined: true,
        agentCreatedScript: false);
    expect(decision.needsJudgment, isTrue);
  });

  test('no enforcing backend refuses, fail closed — even certified with grants',
      () {
    final envelope = CapabilityEnvelope.parse(
        _req('cat', ['/granted/notes.txt']), searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes:
            const _Scopes(reads: {'/granted/notes.txt'}, writes: {'/granted'}),
        confined: false,
        agentCreatedScript: false);
    expect(decision.refuses, isTrue,
        reason: 'the grant authorizes the read, it does not confine');
    expect(decision.reason, contains('fail closed'));
  });

  test('a certified reader inside granted scopes runs', () {
    final envelope = CapabilityEnvelope.parse(
        _req('cat', ['/granted/notes.txt']), searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(reads: {'/granted/notes.txt'}),
        confined: true,
        agentCreatedScript: false);
    expect(decision.runs, isTrue);
  });

  test('a certified reader outside granted scopes goes to judgment', () {
    final envelope = CapabilityEnvelope.parse(
        _req('cat', ['/elsewhere/notes.txt']), searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(reads: {'/granted'}),
        confined: true,
        agentCreatedScript: false);
    expect(decision.needsJudgment, isTrue);
  });

  test('an agent-created script inside the workspace runs without asking',
      () {
    final envelope = CapabilityEnvelope.parse(
        _req('/workspace/run.sh', []), searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(
            reads: {'/workspace'}, writes: {'/workspace'}, plan: {'/workspace'}),
        confined: true,
        agentCreatedScript: true);
    expect(decision.runs, isTrue);
    expect(decision.reason, contains('agent-created'));
  });

  test('an agent-created script reaching outside approved scopes asks', () {
    final envelope = CapabilityEnvelope.parse(
        _req('/workspace/run.sh', ['/etc/passwd']),
        searchPath: '/usr/bin:/bin');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(
            reads: {'/workspace'}, writes: {'/workspace'}, plan: {'/workspace'}),
        confined: true,
        agentCreatedScript: true);
    expect(decision.needsJudgment, isTrue);
  });

  test('an unknown command with unproven effects goes to judgment', () {
    final envelope = CapabilityEnvelope.parse(
        _req('custom-build-tool', ['--link', '/outside']), searchPath: '');
    final decision = decidePermission(envelope,
        scopes: const _Scopes(plan: {'/workspace'}),
        confined: true,
        agentCreatedScript: false);
    expect(decision.needsJudgment, isTrue);
  });
}
