// The failure classifier and the availability decision: recorded exit
// codes and stderr in, the right outcome out; no sandbox binary needed
// anywhere in this file.
//
// Run: dart test
library;

import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

CommandCompleted _completed({
  int exitCode = 1,
  String stdout = '',
  String stderr = '',
}) =>
    CommandCompleted(exitCode: exitCode, stdout: stdout, stderr: stderr);

/// An inner runner that records what it was handed and replays scripted
/// outcomes — the seam the layer-order test reads.
class ScriptedRunner implements ProcessRunner {
  final List<RunOutcome> outcomes;
  final List<ProcessRequest> starts = [];
  int calls = 0;

  ScriptedRunner([this.outcomes = const []]);

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    starts.add(request);
    final outcome = calls < outcomes.length
        ? outcomes[calls]
        : const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
    calls++;
    return outcome;
  }
}

void main() {
  test('approved networking keeps filesystem restrictions for both backends',
      () async {
    for (final backend in [SandboxBackend.sandboxExec, SandboxBackend.bwrap]) {
      final inner = ScriptedRunner();
      final runner = OsSandboxRunner(
          inner: inner,
          plan: const SandboxPlan(workspaceRoot: '/project'),
          backend: backend);
      final request = (
        command: 'git',
        arguments: ['push', 'origin'],
        workingDirectory: '/project',
        environment: null,
        stdin: null,
        timeout: null
      );
      await runner.run(request,
          control: const ProcessControl(networkAllowed: true));
      final args = inner.starts.last.arguments;
      if (backend == SandboxBackend.sandboxExec) {
        expect(args[1], isNot(contains('(deny network*)')));
        expect(args[1], contains('(deny file-write*)'));
        expect(args[1], contains('(subpath "/project")'));
      } else {
        expect(args, isNot(contains('--unshare-net')));
        expect(args, contains('--ro-bind'));
        expect(args, contains('--bind'));
      }
      await runner.run(request);
      if (backend == SandboxBackend.sandboxExec) {
        expect(inner.starts.last.arguments[1], contains('(deny network*)'));
      } else {
        expect(inner.starts.last.arguments, contains('--unshare-net'));
      }
    }
  });

  group('classifySandboxFailure', () {
    const writable = ['/work/proj', '/tmp'];
    final mounted = [...writable, '/usr', '/bin', '/etc'];

    test('a zero exit is never a denial', () {
      final denial = classifySandboxFailure(
        _completed(exitCode: 0, stderr: 'Read-only file system'),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(denial, isNull);
    });

    test(
        'EROFS with an absolute path outside the writable paths is a '
        'write denial naming the path', () {
      final denial = classifySandboxFailure(
        _completed(
          exitCode: 1,
          stderr: 'touch: cannot touch \'/etc/hosts\': '
              'Read-only file system',
        ),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(denial, isA<WriteDenied>());
      expect((denial as WriteDenied).blockedPaths, ['/etc/hosts']);
      expect(denial.explanation, contains('/etc/hosts'));
      expect(denial.recoveryInstructions, contains('outside the sandbox'));
    });

    test('the path may trail the diagnostic or lead it', () {
      for (final stderr in [
        'cp: cannot create \'/var/log/x.log\': Read-only file system',
        '\'/var/log/x.log\': Read-only file system',
      ]) {
        final denial = classifySandboxFailure(
          _completed(exitCode: 1, stderr: stderr),
          writablePaths: writable,
          mountedPaths: mounted,
        );
        expect(denial, isA<WriteDenied>(), reason: stderr);
      }
    });

    test(
        'a path inside the writable layout is ordinary output, not a '
        'denial (grants the gate approved are not kernel failures)', () {
      final denial = classifySandboxFailure(
        _completed(
          exitCode: 1,
          stderr: 'touch: cannot touch \'/tmp/x\': Read-only file system',
        ),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(denial, isNull);
    });

    test(
        '"Permission denied" alone is an ordinary failure — it equally '
        'describes ownership errors', () {
      final denial = classifySandboxFailure(
        _completed(exitCode: 1, stderr: 'cat: /etc/shadow: Permission denied'),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(denial, isNull);
    });

    test(
        'EPERM naming an unmounted path is an operation denial; EPERM '
        'without any path is an ordinary failure', () {
      final named = classifySandboxFailure(
        _completed(
          exitCode: 1,
          stderr: 'sh: /run/secrets/token: Operation not permitted',
        ),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(named, isA<OperationDenied>());

      final bare = classifySandboxFailure(
        _completed(exitCode: 1, stderr: 'some tool: Operation not permitted'),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(bare, isNull);
    });

    test('a failing build stays an ordinary failed command', () {
      final denial = classifySandboxFailure(
        _completed(
          exitCode: 2,
          stdout: 'FAILED: foo_test\ntarget did not compile',
          stderr: '',
        ),
        writablePaths: writable,
        mountedPaths: mounted,
      );
      expect(denial, isNull);
    });
  });

  group('resolveSandboxBackendFor (pure dispatch matrix)', () {
    test('macOS picks sandbox-exec only when the binary is present', () {
      expect(
        resolveSandboxBackendFor(
            isMacOS: true,
            isLinux: false,
            osName: 'macos',
            sandboxExecPresent: true),
        SandboxBackend.sandboxExec,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: true, isLinux: false, osName: 'macos'),
        SandboxBackend.passThrough,
      );
    });

    test('linux picks bwrap only with the binary AND user namespaces', () {
      expect(
        resolveSandboxBackendFor(
            isMacOS: false,
            isLinux: true,
            osName: 'linux',
            bwrapPresent: true,
            userNsEnabled: true),
        SandboxBackend.bwrap,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: false,
            isLinux: true,
            osName: 'linux',
            bwrapPresent: false,
            userNsEnabled: true),
        SandboxBackend.passThrough,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: false,
            isLinux: true,
            osName: 'linux',
            bwrapPresent: true,
            userNsEnabled: false),
        SandboxBackend.passThrough,
      );
    });

    test('unknown platforms pass through and say why', () {
      expect(
        resolveSandboxBackendFor(
            isMacOS: false, isLinux: false, osName: 'windows'),
        SandboxBackend.passThrough,
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: false, isLinux: false, osName: 'windows'),
        'no supported sandbox backend for "windows"',
      );
    });

    test('each degradation names its reason; an active backend names none', () {
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: true,
            isLinux: false,
            osName: 'macos',
            sandboxExecPresent: true),
        isNull,
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: true, isLinux: false, osName: 'macos'),
        'sandbox-exec not found',
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: false, isLinux: true, osName: 'linux'),
        'bwrap not found on PATH',
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: false,
            isLinux: true,
            osName: 'linux',
            bwrapPresent: true,
            userNsEnabled: false),
        'unprivileged user namespaces are disabled',
      );
    });
  });

  group('OsSandboxRunner availability (the explicit fallback)', () {
    test(
        'no backend + allow: the request runs through the inner runner '
        'untouched, once with a warning', () async {
      final inner = ScriptedRunner([
        const CommandCompleted(exitCode: 0, stdout: 'ran free', stderr: ''),
      ]);
      final warnings = <String>[];
      final runner = OsSandboxRunner(
        inner: inner,
        plan: const SandboxPlan(workspaceRoot: '/w'),
        backend: SandboxBackend.passThrough,
        unavailableReason: 'bwrap not found on PATH',
        unavailableBehaviour: UnavailableBehaviour.allow,
        onWarn: warnings.add,
      );
      final outcome = await runner.run((
        command: 'echo',
        arguments: ['hi'],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandCompleted>());
      expect((outcome as CommandCompleted).stdout, 'ran free');
      // Untouched: exactly the original request, no jail argv.
      expect(inner.starts.single.command, 'echo');
      expect(inner.starts.single.arguments, ['hi']);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('bwrap not found on PATH'));
      // The warning fires once, not per command.
      await runner.run((
        command: 'echo',
        arguments: ['again'],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(warnings, hasLength(1));
    });

    test(
        'no backend + refuse: the command is refused, nothing runs, and '
        'the refusal is a CommandRefused (the gate\'s shape), not a '
        'completed failure', () async {
      final inner = ScriptedRunner();
      final runner = OsSandboxRunner(
        inner: inner,
        plan: const SandboxPlan(workspaceRoot: '/w'),
        backend: SandboxBackend.passThrough,
        unavailableReason: 'sandbox-exec not found',
        unavailableBehaviour: UnavailableBehaviour.refuse,
      );
      final outcome = await runner.run((
        command: 'echo',
        arguments: [],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandRefused>());
      expect((outcome as CommandRefused).reason, contains('unavailable'));
      expect(inner.calls, 0, reason: 'nothing may start');
    });
  });

  group('layer order — gate approves, OS denies', () {
    test(
        'through the whole stack (gate over jail over spawn): a request '
        'the gate approves — a shell string whose internals the gate '
        'cannot read — that the kernel then stops comes out '
        'CommandBlocked, not a bare exit and not a refusal', () async {
      final spawn = ScriptedRunner([
        const CommandCompleted(
          exitCode: 1,
          stdout: '',
          stderr: "sh: can't create /etc/hosts: Read-only file system",
        ),
      ]);
      // The composite: our gate outermost, the jail beneath it, a fake
      // spawn innermost. A shell string never rides the writable
      // directories (CommandRule.shellString), so with an approver wired
      // and saying yes, the gate lets it through — whatever the string
      // does is exactly what the OS layer exists for.
      final gate = SandboxedProcessRunner(
        inner: OsSandboxRunner(
          inner: spawn,
          plan: const SandboxPlan(workspaceRoot: '/work/proj'),
          backend: SandboxBackend.bwrap,
          hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: const [],
            temporaryDirectories: const ['/tmp'],
          ),
        ),
        writableDirectories:
            WritableDirectories(['/work/proj', '/tmp', '/var/tmp']),
        approver: (op, reason) async => Approval.yes,
      );
      final outcome = await gate.run((
        command: '/bin/sh',
        arguments: ['-c', 'echo x > /etc/hosts'],
        workingDirectory: '/work/proj',
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandBlocked>());
      expect((outcome as CommandBlocked).reason,
          contains("operating system's sandbox"));
      // The gate let it through (no refusal) and the jail wrapped it:
      // the spawn saw the bwrap argv, then the command verbatim.
      expect(spawn.starts.single.command, 'bwrap');
      final argv = spawn.starts.single.arguments;
      expect(argv.first, startsWith('--'));
      expect(argv, isNot(contains('bwrap')),
          reason: 'bwrap is the executable, never its own first child command');
      expect(argv[argv.length - 3], '/bin/sh');
      expect(argv[argv.length - 2], '-c');
      expect(argv.last, 'echo x > /etc/hosts');
    });

    test(
        'a CommandCompleted failure the classifier blames on the kernel '
        'comes back as CommandBlocked, not a bare exit', () async {
      final inner = ScriptedRunner([
        const CommandCompleted(
          exitCode: 1,
          stdout: '',
          stderr: "touch: cannot touch '/etc/passwd': Read-only file system",
        ),
      ]);
      final runner = OsSandboxRunner(
        inner: inner,
        plan: const SandboxPlan(workspaceRoot: '/work/proj'),
        backend: SandboxBackend.bwrap,
        hostLayout: () => SandboxHostLayout(
          readOnlyDirectories: const [],
          temporaryDirectories: const ['/tmp'],
        ),
      );
      final outcome = await runner.run((
        command: 'touch',
        arguments: ['/etc/passwd'],
        workingDirectory: '/work/proj',
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandBlocked>());
      final blocked = outcome as CommandBlocked;
      expect(blocked.reason, contains("operating system's sandbox"));
      expect(blocked.reason, contains('/etc/passwd'));
      // The jail argv really wrapped the command.
      expect(inner.starts.single.command, 'bwrap');
      expect(inner.starts.single.arguments, contains('--unshare-net'));
      expect(inner.starts.single.arguments.last, '/etc/passwd');
    });

    test('an ordinary failure behind the jail stays CommandCompleted',
        () async {
      final inner = ScriptedRunner([
        const CommandCompleted(exitCode: 2, stdout: 'boom', stderr: ''),
      ]);
      final runner = OsSandboxRunner(
        inner: inner,
        plan: const SandboxPlan(workspaceRoot: '/work/proj'),
        backend: SandboxBackend.bwrap,
        hostLayout: () => SandboxHostLayout(
          readOnlyDirectories: const [],
          temporaryDirectories: const [],
        ),
      );
      final outcome = await runner.run((
        command: 'false',
        arguments: [],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandCompleted>());
      expect((outcome as CommandCompleted).exitCode, 2);
    });

    test('a success behind the jail stays CommandCompleted with its output',
        () async {
      final inner = ScriptedRunner([
        const CommandCompleted(exitCode: 0, stdout: 'ok', stderr: ''),
      ]);
      final runner = OsSandboxRunner(
        inner: inner,
        plan: const SandboxPlan(workspaceRoot: '/work/proj'),
        backend: SandboxBackend.sandboxExec,
        hostLayout: () => SandboxHostLayout(
          readOnlyDirectories: const [],
          temporaryDirectories: const [],
        ),
      );
      await runner.run((
        command: '/bin/echo',
        arguments: ['ok'],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      // sandbox-exec wraps with `-p <profile>` then the command verbatim.
      final argv = inner.starts.single;
      expect(argv.command, 'sandbox-exec');
      expect(argv.arguments[0], '-p');
      expect(argv.arguments[1], contains('(deny file-write*)'));
      expect(argv.arguments[2], '/bin/echo');
      expect(argv.arguments[3], 'ok');
    });
  });
}
