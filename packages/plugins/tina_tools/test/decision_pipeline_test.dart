// The decision pipeline: the live precedence, as one pure function —
// execution profile (Layer-1 fast paths), mode ceilings, backend
// feasibility, grant coverage, then judgment. The fast paths select the
// read-only enforcement profile; the run verdict still comes from grant
// coverage (a certified reader's execution requirement is covered by
// certification; an agent script's still asks).
library;

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

final class _Scopes implements ScopesView {
  const _Scopes({this.reads = const {}});
  final Set<String> reads;

  @override
  bool canRead(String path) => reads.contains(path);

  @override
  bool canWrite(String path) => false;

  @override
  bool withinPlan(String path) => false;
}

ProcessRequest _req(String command, List<String> arguments) => (
      command: command,
      arguments: arguments,
      workingDirectory: '/workspace',
      environment: null,
      stdin: null,
      timeout: null,
    );

const _ask = PermissionMode.ask;
const _readOnly = PermissionMode.readOnly;
const _yolo = PermissionMode.yolo;

PermissionDecision _decide(
  CapabilityEnvelope envelope, {
  ScopesView scopes = const _Scopes(),
  bool confined = true,
  bool network = false,
  bool outsideSandbox = false,
  bool? controlReadOnlyRequested,
  bool agentCreatedScriptArguments = false,
  bool declaredReadsEmpty = true,
  bool declaredWritesEmpty = true,
  PermissionMode mode = _ask,
  bool requirementsCovered = false,
  bool judgmentOutsideWorkspace = false,
}) =>
    decidePermission(envelope,
        scopes: scopes,
        confined: confined,
        network: network,
        outsideSandbox: outsideSandbox,
        controlReadOnlyRequested: controlReadOnlyRequested,
        agentCreatedScriptArguments: agentCreatedScriptArguments,
        declaredReadsEmpty: declaredReadsEmpty,
        declaredWritesEmpty: declaredWritesEmpty,
        mode: mode,
        requirementsCovered: requirementsCovered,
        judgmentOutsideWorkspace: judgmentOutsideWorkspace);

void main() {
  test('the read-only mode ceiling refuses mutations and host execution', () {
    final envelope =
        CapabilityEnvelope.parse(_req('sh', []), searchPath: '/usr/bin:/bin');
    expect(
        _decide(envelope, controlReadOnlyRequested: false, mode: _readOnly)
            .refuses,
        isTrue);
    final outside = _decide(envelope, outsideSandbox: true, mode: _readOnly);
    expect(outside.refuses, isTrue);
    expect(outside.reason, contains('Read-only mode blocks'));
  });

  test('read-only mode without a backend refuses with the mutation message',
      () {
    final envelope = CapabilityEnvelope.parse(_req('cat', ['/workspace/a']),
        searchPath: '/usr/bin:/bin');
    final decision = _decide(envelope, confined: false, mode: _readOnly);
    expect(decision.refuses, isTrue);
    expect(decision.reason,
        contains('read-only mode blocks mutations and host or external'));
  });

  test('a certified reader without a backend asks in ask mode', () {
    // Fail closed shows up as escalation, not silent refusal: without a
    // backend the profile falls back to writable, the host requirement
    // goes uncovered, and only a human can approve it. In read-only mode
    // the ceiling refuses instead (test above).
    final envelope = CapabilityEnvelope.parse(
        _req('cat', ['/granted/notes.txt']),
        searchPath: '/usr/bin:/bin');
    final decision = _decide(envelope,
        scopes: const _Scopes(reads: {'/granted/notes.txt'}),
        confined: false,
        judgmentOutsideWorkspace: true);
    expect(decision.needsJudgment, isTrue);
    expect(decision.readOnlyProfile, isFalse);
  });

  test('a write-profile command without a backend asks, not refuses', () {
    final envelope = CapabilityEnvelope.parse(
        _req('custom-build-tool', ['--link', '/outside']),
        searchPath: '');
    final decision =
        _decide(envelope, controlReadOnlyRequested: false, confined: false);
    expect(decision.needsJudgment, isTrue,
        reason:
            'unconfined execution is human-only: it escalates, never refuses');
  });

  test('covered requirements run, whatever they were covered by', () {
    final envelope = CapabilityEnvelope.parse(_req('make', ['build']),
        searchPath: '/usr/bin:/bin');
    final decision = _decide(envelope,
        controlReadOnlyRequested: false, requirementsCovered: true);
    expect(decision.runs, isTrue);
    expect(decision.rule, PermissionRule.grantsRun);
  });

  test('yolo launch-time authorization runs uncovered requests', () {
    final envelope = CapabilityEnvelope.parse(_req('make', ['build']),
        searchPath: '/usr/bin:/bin');
    expect(_decide(envelope, mode: _yolo).runs, isTrue);
  });

  test('an uncovered workspace write asks with the mutation reason', () {
    final envelope = CapabilityEnvelope.parse(_req('make', ['build']),
        searchPath: '/usr/bin:/bin');
    final decision = _decide(envelope, controlReadOnlyRequested: false);
    expect(decision.needsJudgment, isTrue);
    expect(decision.reason, 'Workspace mutation requires approval');
  });

  test('an uncovered requirement outside the workspace escalates', () {
    final envelope = CapabilityEnvelope.parse(_req('curl', ['https://x.test']),
        control: const ProcessControl(networkRequested: true),
        searchPath: '/usr/bin:/bin');
    final decision = _decide(envelope,
        network: true,
        controlReadOnlyRequested: false,
        judgmentOutsideWorkspace: true);
    expect(decision.needsJudgment, isTrue);
    expect(decision.reason, contains('explicit human approval'));
  });

  group('execution profile (readOnlyProfileOf)', () {
    test('a certified reader with empty declared directories reads enforced',
        () {
      final envelope = CapabilityEnvelope.parse(
          _req('cat', ['/granted/notes.txt']),
          searchPath: '/usr/bin:/bin');
      expect(
          readOnlyProfileOf(envelope,
              scopes: const _Scopes(reads: {'/granted/notes.txt'}),
              confined: true,
              network: false,
              outsideSandbox: false,
              agentCreatedScriptArguments: false,
              declaredReadsEmpty: true,
              declaredWritesEmpty: true,
              mode: _ask),
          isTrue);
    });

    test('a verified read outside granted scopes keeps the default profile',
        () {
      // The fast path is lost, but the mode default still enforces
      // read-only for a certified reader; the grants gate nothing here.
      final envelope = CapabilityEnvelope.parse(
          _req('cat', ['/elsewhere/notes.txt']),
          searchPath: '/usr/bin:/bin');
      expect(
          readOnlyProfileOf(envelope,
              scopes: const _Scopes(reads: {'/granted'}),
              confined: true,
              network: false,
              outsideSandbox: false,
              agentCreatedScriptArguments: false,
              declaredReadsEmpty: true,
              declaredWritesEmpty: true,
              mode: _ask),
          isTrue);
    });

    test('the agent script fast path selects read-only enforcement', () {
      final envelope = CapabilityEnvelope.parse(_req('/workspace/run.sh', []),
          searchPath: '');
      expect(
          readOnlyProfileOf(envelope,
              scopes: const _Scopes(),
              confined: true,
              network: false,
              outsideSandbox: false,
              agentCreatedScriptArguments: true,
              declaredReadsEmpty: true,
              declaredWritesEmpty: true,
              mode: _ask),
          isTrue);
      // Network disables the fast path, but the ask-mode default still
      // enforces read-only for a plain confined command; the decision is
      // what escalates (judgment, outside workspace).
      expect(
          readOnlyProfileOf(envelope,
              scopes: const _Scopes(),
              confined: true,
              network: true,
              outsideSandbox: false,
              agentCreatedScriptArguments: true,
              declaredReadsEmpty: true,
              declaredWritesEmpty: true,
              mode: _ask),
          isTrue);
      expect(
          _decide(envelope,
                  network: true,
                  agentCreatedScriptArguments: true,
                  judgmentOutsideWorkspace: true)
              .needsJudgment,
          isTrue);
    });

    test('an explicit control profile wins over every fast path', () {
      final envelope = CapabilityEnvelope.parse(
          _req('cat', ['/granted/notes.txt']),
          searchPath: '/usr/bin:/bin');
      expect(
          readOnlyProfileOf(envelope,
              scopes: const _Scopes(reads: {'/granted/notes.txt'}),
              confined: true,
              network: false,
              outsideSandbox: false,
              agentCreatedScriptArguments: false,
              declaredReadsEmpty: true,
              declaredWritesEmpty: true,
              controlReadOnlyRequested: false,
              mode: _ask),
          isFalse);
    });

    test('the agent script still asks: only coverage runs', () {
      final envelope = CapabilityEnvelope.parse(_req('/workspace/run.sh', []),
          searchPath: '');
      final decision = _decide(envelope, agentCreatedScriptArguments: true);
      expect(decision.needsJudgment, isTrue,
          reason: 'the fast path enforces read-only; execution still asks');
      expect(decision.readOnlyProfile, isTrue);
      expect(
          _decide(envelope,
                  agentCreatedScriptArguments: true, requirementsCovered: true)
              .runs,
          isTrue);
    });
  });
}
