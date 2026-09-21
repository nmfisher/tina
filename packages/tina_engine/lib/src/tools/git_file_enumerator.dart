import 'dart:async';
import 'dart:convert';

import 'process_runner.dart';

enum GitListingStatus { completed, failed, truncated, timedOut, cancelled }

/// A partial listing must never silently become an exhaustive repository view.
class GitFileListing {
  final List<String> paths;
  final GitListingStatus status;
  final List<String> gaps;
  GitFileListing(Iterable<String> paths, this.status, Iterable<String> gaps)
      : paths = List.unmodifiable(paths),
        gaps = List.unmodifiable(gaps);
}

/// Git-aware enumeration through the caller's process runner. No walk fallback:
/// consumers choose whether unavailable Git may relax their collection policy.
class GitFileEnumerator {
  static const arguments = [
    '--no-optional-locks',
    '-c',
    'core.fsmonitor=false',
    '-c',
    'core.precomposeunicode=false',
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    '.',
  ];

  final ProcessRunner processes;
  final int maxFiles;
  final int maxOutputBytes;
  final int maxPathBytes;
  final Duration timeout;
  final Duration exitTimeout;

  GitFileEnumerator({
    required this.processes,
    this.maxFiles = 100000,
    this.maxOutputBytes = 16 * 1024 * 1024,
    this.maxPathBytes = 4096,
    this.timeout = const Duration(seconds: 10),
    this.exitTimeout = const Duration(seconds: 1),
  }) {
    if (maxFiles <= 0 ||
        maxOutputBytes <= 0 ||
        maxPathBytes <= 0 ||
        timeout <= Duration.zero ||
        exitTimeout <= Duration.zero) {
      throw ArgumentError('Git enumeration limits must be positive');
    }
  }

  Future<GitFileListing> enumerate(String root,
      {Future<void>? cancelSignal}) async {
    final paths = <String>{};
    final gaps = <String>[];
    final outputDone = Completer<void>();
    final stopped = Completer<void>();
    RunningProcess? process;
    StreamSubscription<List<int>>? stdout;
    StreamSubscription<List<int>>? stderr;
    GitListingStatus? status;
    var finished = false;
    void finishOutput() {
      if (!outputDone.isCompleted) outputDone.complete();
    }

    void stop(GitListingStatus reason) {
      if (finished || stopped.isCompleted) return;
      status = reason;
      process?.kill();
      stopped.complete();
      finishOutput();
    }

    cancelSignal?.then((_) => stop(GitListingStatus.cancelled),
        onError: (Object _) => stop(GitListingStatus.cancelled));
    final timer = Timer(timeout, () => stop(GitListingStatus.timedOut));
    final pending = <int>[];
    try {
      // Deliver an already-completed signal before starting a subprocess.
      await Future<void>.value();
      if (!stopped.isCompleted) {
        final starting =
            processes.start('git', arguments, workingDirectory: root);
        // A runner may finish starting after cancellation has returned.
        starting.then((p) {
          if (finished || stopped.isCompleted) p.kill();
        }, onError: (Object _) {});
        process = await Future.any<RunningProcess?>([
          starting,
          stopped.future.then((_) => null),
        ]);
      }
      if (process != null && !stopped.isCompleted) {
        var bytes = 0;
        stderr = process.stderr.listen((_) {}, onError: (Object _) {});
        stdout = process.stdout.listen((chunk) {
          if (stopped.isCompleted) return;
          for (final byte in chunk) {
            if (++bytes > maxOutputBytes) {
              stop(GitListingStatus.truncated);
              return;
            }
            if (byte == 0) {
              try {
                final path = utf8.decode(pending);
                if (path.isNotEmpty && !paths.contains(path)) {
                  if (paths.length >= maxFiles) {
                    stop(GitListingStatus.truncated);
                    return;
                  }
                  paths.add(path);
                }
              } on FormatException {
                if (!gaps.contains('Non-UTF8 filename skipped.')) {
                  gaps.add('Non-UTF8 filename skipped.');
                }
              }
              pending.clear();
            } else {
              if (pending.length >= maxPathBytes) {
                stop(GitListingStatus.truncated);
                return;
              }
              pending.add(byte);
            }
          }
        },
            onError: (Object _) => stop(GitListingStatus.failed),
            onDone: finishOutput);
        await outputDone.future;
        if (!stopped.isCompleted) {
          final code = await Future.any<int?>([
            process.exitCode.timeout(exitTimeout, onTimeout: () {
              stop(GitListingStatus.timedOut);
              return -1;
            }),
            stopped.future.then((_) => null),
          ]);
          status ??= code == 0 && pending.isEmpty
              ? GitListingStatus.completed
              : GitListingStatus.failed;
        }
      }
    } catch (_) {
      status ??= GitListingStatus.failed;
    } finally {
      finished = true;
      timer.cancel();
      process?.kill();
      await stdout?.cancel();
      await stderr?.cancel();
    }
    switch (status!) {
      case GitListingStatus.truncated:
        gaps.add('File enumeration capped at $maxFiles paths / '
            '$maxOutputBytes bytes / $maxPathBytes bytes per path.');
      case GitListingStatus.timedOut:
        gaps.add('File enumeration deadline reached.');
      case GitListingStatus.cancelled:
        gaps.add('Enumeration cancelled.');
      case GitListingStatus.failed:
        gaps.add('Git file enumeration failed.');
      case GitListingStatus.completed:
        break;
    }
    return GitFileListing(paths, status!, gaps);
  }
}

class FileEnumerationException implements Exception {
  final GitFileListing listing;
  const FileEnumerationException(this.listing);
  @override
  String toString() => 'File enumeration ${listing.status.name}: '
      '${listing.gaps.join(' ')}';
}
