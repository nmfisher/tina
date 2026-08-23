import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_process_runner.dart';

void main() {
  // Most cases drive BashTool through a scripted MemoryProcessRunner so no
  // real shell is spawned. A small real-process group at the end exercises
  // IoProcessRunner end-to-end (and covers the one behavior — cwd wiring —
  // that can't be asserted without a real /bin/sh).

  group('BashTool (scripted process)', () {
    test('captures stdout and stderr on success', () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        stdoutChunks: ['hello\n'],
        stderrChunks: ['bye\n'],
      ));
      final r = await BashTool(processRunner: runner)
          .execute({'command': 'echo hello; echo bye >&2'});
      expect(r.isError, isFalse);
      expect(r.content, contains('exit: 0'));
      expect(r.content, contains('hello'));
      expect(r.content, contains('bye'));
    });

    test('non-zero exit is surfaced as isError', () async {
      final runner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 7));
      final r = await BashTool(processRunner: runner).execute({'command': 'exit 7'});
      expect(r.isError, isTrue);
      expect(r.content, contains('exit: 7'));
    });

    test('output above the cap keeps the tail and spills the full output',
        () async {
      final testDir = await Directory.systemTemp.createTemp('tina_bash_test_');
      try {
        // A head of '!'s then a tail of '#'s larger than the cap, so the kept
        // tail is all '#'s (proving we keep the END, not the start) and the
        // dropped head is recoverable from the spilled temp file.
        final head = '!' * 100000;
        final tailBlock = '#' * 250000;
        final runner = MemoryProcessRunner.always(
            MemoryRunningProcess(stdoutChunks: [head, tailBlock]));
        final r = await BashTool(
          processRunner: runner,
          tempDirFactory: () => testDir,
        ).execute({'command': 'flood'});

        // Tail-keep: the displayed stdout is the end (all '#'); the '!' head
        // is gone. The sentinels must be characters that can NEVER appear in
        // the content's fixed parts — headers or the temp path. 'A'/'Z'
        // failed that: Directory.createTemp's random suffix is mixed-case
        // ([a-zA-Z0-9]), and the spill path rides in the content
        // ('full output: /tmp/tina_bash_test_Ax3Z…/…'), so the negative
        // assertion failed on ~20% of runs regardless of suite context
        // (#38). '!' and '#' are outside every alphabet involved.
        expect(r.content, contains('#'));
        expect(r.content, isNot(contains('!')));
        expect(r.content, contains('truncated'));
        expect(r.content, contains('full output:'));

        // Spill: the temp file holds the FULL output (head + tail).
        final match = RegExp(r'full output: ([^\n)]+)').firstMatch(r.content);
        expect(match, isNotNull);
        final spillPath = match!.group(1)!.trim();
        final spilled = await File(spillPath).readAsString();
        expect(spilled.length, 350000);
        expect(spilled, contains('!'));
        expect(spilled, contains('#'));
      } finally {
        await testDir.delete(recursive: true);
      }
    });

    test('cancelSignal kills the process and marks the result cancelled',
        () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        hangUntilKilled: true,
        exitCodeValue: 143,
      ));
      final t = BashTool(processRunner: runner);
      final cancel = Completer<void>();
      final f = t.execute(
        {'command': 'sleep 30'},
        cancelSignal: cancel.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancel.complete();
      final r = await f.timeout(const Duration(seconds: 5));
      expect(r.isError, isTrue);
      expect(r.content, contains('cancelled by user'));
    });

    test('timeout still kills hung commands', () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        hangUntilKilled: true,
        exitCodeValue: 143,
      ));
      final t = BashTool(
        timeout: const Duration(milliseconds: 200),
        processRunner: runner,
      );
      final r = await t
          .execute({'command': 'sleep 5'})
          .timeout(const Duration(seconds: 3));
      expect(r.isError, isTrue);
      expect(r.content, contains('exit:'));
    });

    test('missing cwd is rejected early', () async {
      final r = await BashTool(
        processRunner: MemoryProcessRunner.always(MemoryRunningProcess()),
      ).execute({
        'command': 'echo hi',
        'cwd': '/no/such/dir-tina',
      });
      expect(r.isError, isTrue);
      expect(r.content, contains('cwd does not exist'));
    });

    test('onOutput streams stdout and stderr chunks', () async {
      final runner = MemoryProcessRunner.always(MemoryRunningProcess(
        stdoutChunks: ['hello\n'],
        stderrChunks: ['bye\n'],
      ));
      final stdoutChunks = <String>[];
      final stderrChunks = <String>[];
      await BashTool(processRunner: runner).execute(
        {'command': 'echo hello; echo bye >&2'},
        onOutput: (chunk, {bool stderr = false}) {
          (stderr ? stderrChunks : stdoutChunks).add(chunk);
        },
      );
      expect(stdoutChunks.join(), contains('hello'));
      expect(stderrChunks.join(), contains('bye'));
    });

    test('rejects an empty command', () async {
      final r = await BashTool(
        processRunner: MemoryProcessRunner.always(MemoryRunningProcess()),
      ).execute({'command': ''});
      expect(r.isError, isTrue);
      expect(r.content, contains('command is required'));
    });
  });

  group('BashTool (real process)', () {
    test('cwd input runs the command in that directory', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_bash_cwd_');
      try {
        final r = await BashTool().execute({
          'command': 'pwd',
          'cwd': tmp.path,
        });
        expect(r.isError, isFalse);
        expect(r.content, contains(tmp.path));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
