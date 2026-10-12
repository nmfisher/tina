/// FULL-durability transaction benchmark and disposable crash-test writer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tina_sqlite/tina_sqlite.dart';

void main(List<String> args) {
  final mode = args[0];
  final db = openTinaDatabase(
    args[1],
    schemaVersion: 1,
    migrate: createEntryLogTable,
  );
  final log = TinaEntryLog.attach(db);
  if (mode == 'before' || mode == 'after') {
    log.append({'baseline': true});
    // Disable automatic checkpoints so recovery must read the WAL.
    db.execute('PRAGMA wal_autocheckpoint=0');
    void signalAndWait() {
      File(args[2]).writeAsStringSync(mode, flush: true);
      stdin.readLineSync(); // Parent SIGKILLs this disposable process group.
      throw StateError('crash writer must be killed, not resumed');
    }

    if (mode == 'before') {
      db.commitFilter = () {
        signalAndWait();
        return true;
      };
    }
    log.appendAll([
      for (var i = 0; i < 1000; i++) {'seq': i, 'text': 'x' * 4096},
    ]);
    signalAndWait();
  } else if (mode == 'concurrent') {
    final writer = args[2];
    for (var start = 0; start < 1000; start += 10) {
      log.appendAll([
        for (var i = start; i < start + 10; i++) {'writer': writer, 'seq': i},
      ]);
    }
  } else if (mode == 'bench') {
    var commits = 0;
    db.commitFilter = () {
      commits++;
      return true;
    };
    final timings = <String, List<double>>{'individual': [], 'batched': []};
    final counts = <String, int>{};
    // Alternate order; both paths run against the same FULL connection.
    for (var sample = 0; sample < 100; sample++) {
      for (final batched in sample.isEven ? [false, true] : [true, false]) {
        final name = batched ? 'batched' : 'individual';
        final before = commits;
        final clock = Stopwatch()..start();
        final initial = [
          {'type': 'registration', 'sample': sample},
          {'type': 'turn_started', 'sample': sample},
          {'type': 'input_recorded', 'text': 'hello', 'sample': sample},
        ];
        if (batched) {
          log.appendAll(initial);
        } else {
          for (final entry in initial) {
            log.append(entry);
          }
        }
        // A separate durability boundary after input preparation.
        log.append({
          'type': 'message_appended',
          'text': 'hello',
          'sample': sample,
        });
        timings[name]!.add(clock.elapsedMicroseconds / 1000);
        counts[name] = commits - before;
      }
    }
    stdout.writeln(
      jsonEncode({
        'sqlite_version': db.select('SELECT sqlite_version() AS v').single['v'],
        'synchronous': db.select('PRAGMA synchronous').single['synchronous'],
        'journal_mode': db.select('PRAGMA journal_mode').single['journal_mode'],
        'commits_per_sample': counts,
        'milliseconds': timings,
      }),
    );
  } else {
    throw ArgumentError('expected bench, before, after, or concurrent');
  }
  db.close();
}
