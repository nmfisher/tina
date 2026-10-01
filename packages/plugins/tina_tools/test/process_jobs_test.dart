import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  for (final toolName in ['exec', 'bash']) {
    test(
        '$toolName background starts only after approval and remains inspectable',
        () async {
      final dir = Directory.systemTemp.createTempSync('tina-background-');
      final decision = Completer<Approval>();
      final asked = Completer<void>();
      final jobs = ProcessJobs(SandboxedProcessRunner(
        inner: const IoProcessRunner(),
        approver: (_, __) {
          asked.complete();
          return decision.future;
        },
      ));
      addTearDown(() async {
        if (!decision.isCompleted) decision.complete(Approval.no);
        await jobs.close();
        dir.deleteSync(recursive: true);
      });
      const command =
          'echo started > started; while [ ! -f finish ]; do sleep 0.05; done; echo background-finished';
      final input = <String, dynamic>{
        'background': true,
        'timeout': 20,
        if (toolName == 'exec') ...{
          'program': '/bin/sh',
          'args': ['-c', command]
        } else
          'command': command,
      };
      final tool = toolName == 'exec'
          ? ExecTool(runner: jobs, workingDirectory: dir.path)
          : BashTool(runner: jobs, workingDirectory: dir.path);
      var returned = false;
      final run = tool.execute(input).then((result) {
        returned = true;
        return result;
      });
      await asked.future.timeout(const Duration(seconds: 3));
      expect(returned, false,
          reason: 'a pending approval is not a running background job');
      expect(File('${dir.path}/started').existsSync(), false);
      decision.complete(Approval.yes);
      final result = await run.timeout(const Duration(seconds: 3));
      expect(result.isError, false);
      final jobId =
          RegExp(r'Job ID: ([^ .\n]+)').firstMatch(result.content)!.group(1)!;
      expect((await jobs.inspect({'job_id': jobId})).content,
          contains('still running'));
      File('${dir.path}/finish').writeAsStringSync('done');
      expect(
          (await jobs.inspect(
                  {'job_id': jobId, 'action': 'wait', 'wait_ms': 3000}))
              .content,
          contains('background-finished'));
    });
  }

  test('background cannot bypass denial or invalid input', () async {
    final dir = Directory.systemTemp.createTempSync('tina-background-denied-');
    final jobs = ProcessJobs(SandboxedProcessRunner(
        inner: const IoProcessRunner(),
        approver: (_, __) async => Approval.no));
    addTearDown(() async {
      await jobs.close();
      dir.deleteSync(recursive: true);
    });
    final tool = BashTool(runner: jobs, workingDirectory: dir.path);
    for (final background in [true, 'true']) {
      final result = await tool
          .execute({'command': 'touch forbidden', 'background': background});
      expect(result.isError, true);
      expect(result.content, isNot(contains('Job ID:')));
      expect(File('${dir.path}/forbidden').existsSync(), false);
    }
  });

  for (final shutdown in [false, true]) {
    test(
        '${shutdown ? 'session shutdown' : 'explicit cancellation'} stops a detached real process',
        () async {
      final jobs = ProcessJobs(const IoProcessRunner());
      addTearDown(jobs.close);
      final pending = Completer<void>();
      final originalCancel = Completer<void>();
      final ready = Completer<int>();
      final run = jobs.run((
        command: '/bin/sh',
        arguments: ['-c', 'echo pid:\$\$; exec sleep 60'],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: const Duration(seconds: 70)
      ),
          control: ProcessControl(
              whenInputPending: pending.future,
              whenCancelled: originalCancel.future,
              isCancelled: () => originalCancel.isCompleted,
              onOutput: (text, {isError = false}) {
                final match = RegExp(r'pid:(\d+)').firstMatch(text);
                if (match != null && !ready.isCompleted)
                  ready.complete(int.parse(match[1]!));
              }));
      final pid = await ready.future.timeout(const Duration(seconds: 3));
      addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));
      pending.complete();
      final result = await run as CommandRunning;
      // Cancellation of the old foreground turn no longer owns this job.
      originalCancel.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await jobs.inspect({'job_id': result.id})).content,
          contains('still running'));
      if (shutdown) {
        await jobs.close();
      } else {
        final cancelled =
            await jobs.inspect({'job_id': result.id, 'action': 'cancel'});
        expect(cancelled.isError, true);
      }
      expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
    });
  }

  test(
      'a real process survives new input and interruptible waits; result remains available',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-jobs-');
    final jobs = ProcessJobs(const IoProcessRunner());
    addTearDown(() async {
      await jobs.close();
      dir.deleteSync(recursive: true);
    });
    final pending = Completer<void>();
    final ready = Completer<void>();
    final running = jobs.run((
      command: '/bin/sh',
      arguments: [
        '-c',
        'echo ready; while [ ! -f "${dir.path}/finish" ]; do sleep 0.05; done; echo finished'
      ],
      workingDirectory: dir.path,
      environment: null,
      stdin: null,
      timeout: const Duration(seconds: 10)
    ),
        control: ProcessControl(
            whenInputPending: pending.future,
            onOutput: (text, {isError = false}) {
              if (text.contains('ready') && !ready.isCompleted)
                ready.complete();
            }));
    await ready.future.timeout(const Duration(seconds: 3));
    pending.complete();
    final result =
        await running.timeout(const Duration(seconds: 2)) as CommandRunning;
    expect(result.output, contains('ready'));
    expect((await jobs.inspect({'job_id': result.id})).content,
        contains('still running'));
    final nextInput = Completer<void>();
    final waiting = jobs.inspect({'job_id': result.id, 'action': 'wait'},
        control: ProcessControl(whenInputPending: nextInput.future));
    nextInput.complete();
    expect((await waiting.timeout(const Duration(seconds: 2))).content,
        contains('still running'));
    File('${dir.path}/finish').writeAsStringSync('finish');
    final complete =
        await jobs.inspect({'job_id': result.id, 'action': 'wait'});
    expect(complete.content, contains('exit code: 0'));
    expect(complete.content, contains('finished'));
  });

  test(
      'a new host message reaches the model while its actual process keeps running',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-job-host-');
    final tools = ToolsPlugin(
        workspaceRoot: dir.path,
        tinaDir: Directory('${dir.path}/.tina'),
        osSandbox: false);
    tools.processRunner.commandApprover = (_, __) async => Approval.yes;
    final ready = Completer<void>();
    final waitInput = <String, dynamic>{'action': 'wait'};
    final provider = ScriptedProvider([
      scriptedReply('', calls: [
        ToolUseBlock(id: 'run', name: 'bash', input: {
          'command':
              'echo ready; while [ ! -f "${dir.path}/finish" ]; do sleep 0.05; done; echo completed',
        })
      ]),
      scriptedReply('I can answer while the command runs'),
      scriptedReply('',
          calls: [ToolUseBlock(id: 'wait', name: 'process', input: waitInput)]),
      scriptedReply('command completed'),
    ]);
    final host = Host.start(HostConfig(
        workingDirectory: dir.path,
        providerFactory: (_) => provider,
        plugins: [tools]));
    final subscription = host.session.loop.toolActivity.listen((event) {
      if (event is ToolOutput &&
          event.text.contains('ready') &&
          !ready.isCompleted) ready.complete();
    });
    addTearDown(() async {
      host.close();
      await tools.processJobs.close();
      await subscription.cancel();
      dir.deleteSync(recursive: true);
    });
    final first = host.send('start the command');
    await ready.future.timeout(const Duration(seconds: 3));
    expect(host.offerInput('check the README meanwhile'), true);
    expect((await first.timeout(const Duration(seconds: 3))).detail,
        contains('while the command runs'));
    expect(host.session.turns, hasLength(2));
    expect(File('${dir.path}/finish').existsSync(), false);
    final firstResult = host.session.loop
        .derive()
        .messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>()
        .first;
    final jobId = RegExp(r'Job ID: ([^ .\n]+)')
        .firstMatch(firstResult.content)!
        .group(1)!;
    waitInput['job_id'] = jobId;
    expect((await tools.processJobs.inspect({'job_id': jobId})).content,
        contains('still running'));
    File('${dir.path}/finish').writeAsStringSync('finish');
    expect((await host.send('get the result')).detail, 'command completed');
    final blocks = host.session.loop
        .derive()
        .messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>();
    expect(blocks.first.content, contains('Job ID: $jobId'));
    expect(blocks.last.content, contains('completed'));
  });
}
