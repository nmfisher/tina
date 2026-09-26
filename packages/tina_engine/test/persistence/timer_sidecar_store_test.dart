import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_engine/src/persistence/timer_sidecar_store.dart';

import '../helpers/memory_file_system.dart';

void main() {
  const transcript = '/sessions/abc-123/session.jsonl';
  const sid = 'abc-123';
  const expectedPath = '/sessions/abc-123/abc-123.timers.json';

  Map<String, Object?> record({
    String name = 'check-build',
    int everyMs = 300000,
    String instruction = 'run dart test and report failures',
    bool once = false,
    int? maxFires,
    int fireCount = 12,
    int consecutiveAbortedFires = 0,
    bool suspended = false,
    int anchorEpochMs = 1730000000000,
  }) =>
      {
        'name': name,
        'everyMs': everyMs,
        'instruction': instruction,
        'once': once,
        'maxFires': maxFires,
        'fireCount': fireCount,
        'consecutiveAbortedFires': consecutiveAbortedFires,
        'suspended': suspended,
        'anchorEpochMs': anchorEpochMs,
      };

  group('sidecarPathFor', () {
    test('sits beside the transcript, named <session-id>.timers.json', () {
      expect(TimerSidecarStore.sidecarPathFor(transcript, sid), expectedPath);
    });

    test('handles a bare file name', () {
      expect(TimerSidecarStore.sidecarPathFor('session.jsonl', 's1'),
          's1.timers.json');
    });
  });

  group('write', () {
    test('writes the §10 version-1 schema verbatim, atomically', () async {
      final fs = MemoryFileSystem();
      final store = TimerSidecarStore(fs);
      await store.write(transcript, sid, [record()]);
      final raw = fs.files[expectedPath]!;
      // Atomic write: final file present, no temp litter.
      expect(fs.files.containsKey('.tina-write-$sid.timers.json'), isFalse);
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      expect(doc['version'], 1);
      expect(doc['timers'], hasLength(1));
      expect(doc['timers'][0], {
        'name': 'check-build',
        'everyMs': 300000,
        'instruction': 'run dart test and report failures',
        'once': false,
        'maxFires': null,
        'fireCount': 12,
        'consecutiveAbortedFires': 0,
        'suspended': false,
        'anchorEpochMs': 1730000000000,
      });
      expect(raw.endsWith('\n'), isTrue);
    });

    test('rewrites in place on a second write', () async {
      final fs = MemoryFileSystem();
      final store = TimerSidecarStore(fs);
      await store.write(transcript, sid, [record()]);
      await store.write(transcript, sid, [record(name: 'second')]);
      final doc =
          jsonDecode(fs.files[expectedPath]!) as Map<String, dynamic>;
      expect((doc['timers'] as List).single['name'], 'second');
    });

    test('empty timer list deletes the sidecar', () async {
      final fs = MemoryFileSystem();
      final store = TimerSidecarStore(fs);
      await store.write(transcript, sid, [record()]);
      await store.write(transcript, sid, []);
      expect(fs.files.containsKey(expectedPath), isFalse);
    });

    test('empty write on a never-written session is a no-op', () async {
      final fs = MemoryFileSystem();
      final store = TimerSidecarStore(fs);
      await store.write(transcript, sid, []);
      expect(fs.files.containsKey(expectedPath), isFalse);
    });
  });

  group('read', () {
    test('missing sidecar -> null, silent', () async {
      final fs = MemoryFileSystem();
      final store = TimerSidecarStore(fs);
      final warnings = <String>[];
      final notices = <String>[];
      final result = await store.read(transcript, sid,
          onWarning: warnings.add, onNotice: notices.add);
      expect(result, isNull);
      expect(warnings, isEmpty);
      expect(notices, isEmpty);
    });

    test('round-trips what write produced', () async {
      final fs = MemoryFileSystem();
      final store = TimerSidecarStore(fs);
      await store.write(transcript, sid, [record()]);
      final read = await store.read(transcript, sid);
      expect(read, hasLength(1));
      expect(read!.single['name'], 'check-build');
      expect(read.single['fireCount'], 12);
      expect(read.single['everyMs'], 300000);
    });

    test('unknown fields inside version 1 are tolerated (forward-compat)',
        () async {
      final fs = MemoryFileSystem({
        expectedPath: jsonEncode({
          'version': 1,
          'timers': [
            {
              ...record(),
              'brandNewField': 'whatever',
            },
          ],
        }),
      });
      final store = TimerSidecarStore(fs);
      final warnings = <String>[];
      final read = await store.read(transcript, sid, onWarning: warnings.add);
      expect(warnings, isEmpty);
      expect(read, hasLength(1));
      expect(read!.single['brandNewField'], 'whatever');
    });

    test('malformed entries are dropped, good ones kept', () async {
      final fs = MemoryFileSystem({
        expectedPath: jsonEncode({
          'version': 1,
          'timers': [
            'not-a-map',
            record(),
          ],
        }),
      });
      final store = TimerSidecarStore(fs);
      final read = await store.read(transcript, sid);
      expect(read, hasLength(1));
      expect(read!.single['name'], 'check-build');
    });

    test('unknown VERSION is ignored whole, with a notice', () async {
      final fs = MemoryFileSystem({
        expectedPath: jsonEncode({
          'version': 999,
          'timers': [record()],
        }),
      });
      final store = TimerSidecarStore(fs);
      final notices = <String>[];
      final result = await store.read(transcript, sid, onNotice: notices.add);
      expect(result, isNull);
      expect(notices, hasLength(1));
      expect(notices.single, contains('999'));
    });

    test('corrupt JSON -> null with a warning', () async {
      final fs = MemoryFileSystem({expectedPath: '{not json'});
      final store = TimerSidecarStore(fs);
      final warnings = <String>[];
      final result = await store.read(transcript, sid, onWarning: warnings.add);
      expect(result, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('corrupt'));
    });

    test('non-object JSON -> null with a warning', () async {
      final fs = MemoryFileSystem({expectedPath: '[1,2,3]'});
      final store = TimerSidecarStore(fs);
      final warnings = <String>[];
      final result = await store.read(transcript, sid, onWarning: warnings.add);
      expect(result, isNull);
      expect(warnings, hasLength(1));
    });

    test('timers not a list -> null with a warning', () async {
      final fs = MemoryFileSystem({
        expectedPath: jsonEncode({'version': 1, 'timers': 7}),
      });
      final store = TimerSidecarStore(fs);
      final warnings = <String>[];
      final result = await store.read(transcript, sid, onWarning: warnings.add);
      expect(result, isNull);
      expect(warnings, hasLength(1));
    });

    test('timers not a list -> null with a warning', () async {
      final fs = MemoryFileSystem({
        expectedPath: jsonEncode({'version': 1}),
      });
      final store = TimerSidecarStore(fs);
      final read = await store.read(transcript, sid);
      expect(read, isEmpty);
    });
  });

  group('classifySavedTimer (§10 step 3 table, §11)', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1730000000000);
    final nowMs = now.millisecondsSinceEpoch;

    test('one-off with anchor past → expired', () {
      expect(
          classifySavedTimer(
              record(once: true, anchorEpochMs: nowMs - 1), now),
          TimerSidecarClassification.expired);
    });

    test('boundary: one-off with anchor exactly now → expired', () {
      expect(
          classifySavedTimer(record(once: true, anchorEpochMs: nowMs), now),
          TimerSidecarClassification.expired);
    });

    test('one-off with anchor in the future → restorable', () {
      expect(
          classifySavedTimer(
              record(once: true, anchorEpochMs: nowMs + 1), now),
          TimerSidecarClassification.restorable);
    });

    test('maxFires reached (fireCount == maxFires) → completed', () {
      expect(
          classifySavedTimer(
              record(maxFires: 4, fireCount: 4, anchorEpochMs: nowMs + 1),
              now),
          TimerSidecarClassification.completed);
    });

    test('maxFires exceeded (fireCount > maxFires) → completed', () {
      expect(
          classifySavedTimer(
              record(maxFires: 4, fireCount: 7, anchorEpochMs: nowMs + 1),
              now),
          TimerSidecarClassification.completed);
    });

    test('once with an explicit maxFires and a past anchor → expired '
        '(expired wins over completed)', () {
      expect(
          classifySavedTimer(
              record(once: true, maxFires: 1, fireCount: 1,
                  anchorEpochMs: nowMs),
              now),
          TimerSidecarClassification.expired);
    });

    test('recurring under the cap → restorable regardless of anchor', () {
      expect(
          classifySavedTimer(
              record(maxFires: 4, fireCount: 2, anchorEpochMs: nowMs - 1),
              now),
          TimerSidecarClassification.restorable);
      expect(classifySavedTimer(record(anchorEpochMs: nowMs + 1), now),
          TimerSidecarClassification.restorable);
    });

    test('capped timer that has NOT used its fires → restorable', () {
      expect(
          classifySavedTimer(
              record(once: false, maxFires: 10, fireCount: 3,
                  anchorEpochMs: nowMs + 1),
              now),
          TimerSidecarClassification.restorable);
    });

    test('malformed records fall through to restorable (restore skips '
        'them silently)', () {
      expect(classifySavedTimer(record(anchorEpochMs: 0), now),
          isNotNull, reason: 'no crash on a degenerate anchor');
    });
  });
}
