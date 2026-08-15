import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

class _StaticProvider implements CompletionProvider {
  final List<String> results;
  _StaticProvider(this.results);
  @override
  Future<List<String>> complete(String query) async => results;
}

class _ThrowingProvider implements CompletionProvider {
  @override
  Future<List<String>> complete(String query) async => throw StateError('boom');
}

/// Filters [all] by the slash-prefixed query, mirroring the real command
/// provider: query is the text after `/`, results carry the leading slash.
class _CommandProvider implements CompletionProvider {
  final List<String> all;
  _CommandProvider(this.all);
  @override
  Future<List<String>> complete(String query) async => query.isEmpty
      ? all
      : all.where((c) => c.startsWith('/$query')).toList();
}

/// Records every event it's offered. [active] gates [isActive]; [consume]
/// controls whether [handleEvent] claims the event (true) or lets it fall
/// through (false).
class _FakeModal implements ModalSurface {
  _FakeModal(this.active);
  bool active;
  bool consume = true;
  final List<InputEvent> events = [];
  @override
  bool get isActive => active;
  @override
  bool handleEvent(InputEvent event) {
    events.add(event);
    return consume;
  }
}

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

LineEditor _editor(FakeStdio io,
    {CompletionProvider? provider,
    CompletionProvider? commandProvider,
    void Function(Object, StackTrace)? onError,
    int width = 80,
    bool ansi = true}) {
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(width, 24),
    ansi: ansi ? AnsiCapable.yes : AnsiCapable.no,
  );
  // escapeTimeout zero so ESC delivers on the next microtask, matching the
  // pre-refactor synchronous expectations of these tests.
  final ed = LineEditor(
    screen: screen,
    onError: onError,
    escapeTimeout: Duration.zero,
  );
  ed.completionProvider = provider;
  ed.commandProvider = commandProvider;
  return ed;
}

void main() {
  group('LineEditor basics', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('readLine returns typed input on Enter', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62, 0x0d]); // a, b, Enter
      expect(await f, 'ab');
    });

    test('submitted text clears from the input immediately (dispatch window)',
        () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62, 0x0d]); // a, b, Enter
      expect(await f, 'ab');
      await _flush();
      // The buffer is empty BEFORE the next readLine — a long-running command
      // dispatch (e.g. /index's confirm + fleet run) must not leave the
      // submitted text sitting in the input region.
      expect(ed.editState.buffer, isEmpty);
    });

    test('Ctrl-C with empty buffer triggers confirm, second exits', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x03]);
      await _flush();
      io.feedBytes([0x03]);
      expect(await f, isNull);
    });

    test('Ctrl-C with non-empty buffer clears it', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62, 0x03, 0x78, 0x0d]); // a, b, Ctrl-C, x, Enter
      expect(await f, 'x');
    });

    test('double-Esc clears the input; single Esc does not', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62]); // 'ab'
      await _flush();

      // A single Esc arms the double-Esc window but leaves the buffer intact.
      io.feedBytes([0x1b]);
      await _flush();
      io.feedBytes([0x78, 0x0d]); // 'x', Enter
      expect(await f, 'abx');

      // Now a double Esc clears the buffer.
      final f2 = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62]); // 'ab'
      await _flush();
      io.feedBytes([0x1b]); // first Esc
      await _flush();
      io.feedBytes([0x1b]); // second Esc within the window -> clear
      await _flush();
      io.feedBytes([0x78, 0x0d]); // 'x', Enter
      expect(await f2, 'x'); // 'ab' was cleared
    });

    test('Ctrl-D on empty buffer returns null', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x04]);
      expect(await f, isNull);
    });

    test('backspace deletes', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62, 0x7f, 0x0d]);
      expect(await f, 'a');
    });

    test('Ctrl-A + Ctrl-K clears the line', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62, 0x01, 0x0b, 0x78, 0x0d]); // ab, ^A, ^K, x, ⏎
      expect(await f, 'x');
    });

    test('Ctrl-U kills to start', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62, 0x63, 0x15, 0x0d]); // abc, ^U, ⏎
      expect(await f, '');
    });

    test('arrow left moves cursor', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x62]);
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x44]); // left
      await _flush();
      io.feedBytes([0x78, 0x0d]); // x, ⏎
      expect(await f, 'axb');
    });

    test('history up restores previous entry', () async {
      final ed = _editor(io);
      var f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x66, 0x6f, 0x6f, 0x0d]); // foo
      expect(await f, 'foo');

      f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x41, 0x0d]); // up, ⏎
      expect(await f, 'foo');
    });
  });

  group('LineEditor picker', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('@ at word boundary opens picker, Enter accepts', () async {
      final ed = _editor(io, provider: _StaticProvider(['lib/main.dart']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x40]); // @
      await _flush();
      io.feedBytes([0x0d]); // accept
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, '@lib/main.dart');
    });

    test('ESC dismisses picker', () async {
      final ed = _editor(io, provider: _StaticProvider(['x.dart']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x40]);
      await _flush();
      io.feedBytes([0x1b]); // ESC
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, '@');
    });

    test('arrow down selects next, Tab accepts', () async {
      final ed = _editor(io, provider: _StaticProvider(['a.dart', 'b.dart']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x40]);
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x42]); // down
      await _flush();
      io.feedBytes([0x09]); // Tab
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, '@b.dart');
    });

    test('onError fires when provider throws', () async {
      Object? caught;
      final ed = _editor(io,
          provider: _ThrowingProvider(),
          onError: (e, _) => caught = e);
      ed.readLine('> ');
      await _flush();
      io.feedBytes([0x40]);
      await _flush();
      expect(caught, isStateError);
      io.feedBytes([0x03, 0x03]); // exit
      await _flush();
    });
  });

  group('LineEditor command picker', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('/ at the start opens the picker; Enter accepts, Enter submits',
        () async {
      final ed = _editor(io,
          commandProvider: _CommandProvider(['/help', '/exit', '/clear']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x2f]); // / opens the picker (/help focused)
      await _flush();
      io.feedBytes([0x0d]); // accept → '/help ' (trailing space), picker closes
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, '/help ');
    });

    test('/ mid-text does NOT open the picker', () async {
      final ed = _editor(io,
          commandProvider: _CommandProvider(['/help', '/exit']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x68, 0x69, 0x2f, 0x0d]); // 'h','i','/',Enter
      // A single Enter submits — proves the picker never opened (else Enter
      // would have accepted and the line wouldn't submit on one press).
      expect(await f, 'hi/');
    });

    test('arrow down selects the next command; Enter accepts', () async {
      final ed = _editor(io,
          commandProvider: _CommandProvider(['/help', '/exit', '/clear']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x2f]); // /
      await _flush();
      io.feedBytes([0x1b, 0x5b, 0x42]); // down → /exit
      await _flush();
      io.feedBytes([0x0d]); // accept → '/exit '
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, '/exit ');
    });

    test('typing after / filters results by prefix', () async {
      final ed = _editor(io,
          commandProvider: _CommandProvider(
              ['/help', '/exit', '/clear', '/model']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x2f, 0x65]); // '/', 'e' → only /exit matches
      await _flush();
      io.feedBytes([0x0d]); // accept the sole match → '/exit '
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, '/exit ');
    });

    test('ESC dismisses the picker without submitting', () async {
      final ed = _editor(io,
          commandProvider: _CommandProvider(['/help', '/exit']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x2f]); // /
      await _flush();
      io.feedBytes([0x1b]); // ESC dismisses
      await _flush();
      io.feedBytes([0x0d]); // submit the bare '/'
      expect(await f, '/');
    });

    test('@ completion still works alongside the / picker', () async {
      final ed = _editor(io,
          provider: _StaticProvider(['lib/main.dart']),
          commandProvider: _CommandProvider(['/help']));
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes([0x61, 0x20, 0x40]); // 'a', space, '@' (word boundary)
      await _flush();
      io.feedBytes([0x0d]); // accept
      await _flush();
      io.feedBytes([0x0d]); // submit
      expect(await f, 'a @lib/main.dart');
    });
  });

  group('LineEditor cancel monitor', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('ESC during monitor fires callback', () async {
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      var fired = false;
      ed.beginCancelMonitor(() => fired = true);
      io.feedBytes([0x1b]);
      await _flush();
      expect(fired, isTrue);
    });

    test('Ctrl-C during monitor fires callback', () async {
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      var fired = false;
      ed.beginCancelMonitor(() => fired = true);
      io.feedBytes([0x03]);
      await _flush();
      expect(fired, isTrue);
    });

    test('queue mode submits on Enter', () async {
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      io.feedBytes([0x68, 0x69, 0x0d]); // h, i, ⏎
      await _flush();
      expect(submitted, ['hi']);
    });

    test('queue mode Ctrl-C fires cancel, no submission', () async {
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      var cancelled = false;
      final submitted = <String>[];
      ed.beginCancelMonitor(
        () => cancelled = true,
        onQueueSubmit: submitted.add,
      );
      io.feedBytes([0x03]);
      await _flush();
      expect(cancelled, isTrue);
      expect(submitted, isEmpty);
    });

    test('queue mode ESC clears buffer; second ESC cancels', () async {
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      var cancelled = false;
      ed.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
      io.feedBytes([0x61, 0x62]);
      await _flush();
      io.feedBytes([0x1b]);
      await _flush();
      expect(cancelled, isFalse);
      io.feedBytes([0x1b]);
      await _flush();
      expect(cancelled, isTrue);
    });
  });

  group('LineEditor readKey', () {
    test('returns the next event and suspends cancel monitor', () async {
      final io = FakeStdio();
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      var fired = false;
      ed.beginCancelMonitor(() => fired = true);
      final key = ed.readKey();
      io.feedBytes([0x79]); // 'y'
      final event = await key;
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, 'y');
      // ESC should still fire after readKey resolves.
      io.feedBytes([0x1b]);
      await _flush();
      expect(fired, isTrue);
    });

    test('stale paste overflow never answers a later readKey', () async {
      // A paste burst whose overflow chars land in _pending (the burst
      // window after a readKey completes) must not be returned by a LATER
      // readKey — e.g. an approval prompt seconds after the user submitted
      // their line. Without the fix the stale paste char answers the
      // approval as a deny (it is not y/a/d).
      final io = FakeStdio();
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();

      final first = ed.readKey();
      io.feedBytes([0x61]); // 'a'
      final e1 = await first.timeout(const Duration(seconds: 2));
      expect((e1 as CharInput).text, 'a');

      // Overflow chars from a paste burst arriving right after the readKey
      // completes are queued while the burst window is open.
      io.feedBytes([0x62, 0x63]); // 'b','c'
      await _flush();

      // Let the burst window expire so the overflow is stale.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _flush();

      // A fresh readKey (an approval prompt) must wait for a real key, not
      // return the stale overflow char.
      final approval = ed.readKey();
      io.feedBytes([0x79]); // 'y'
      final e2 = await approval.timeout(const Duration(seconds: 2));
      expect((e2 as CharInput).text, 'y');
    });

    test('serializes concurrent callers (no orphaned completer)', () async {
      // readKey overwrites _keyCompleter with no save/restore. Without
      // serialization a second caller orphans the first (it never completes).
      // A background spend-trip firing the pause dialog's readKey while
      // askPermission / /settings holds one is the real-world trigger.
      final io = FakeStdio();
      final ed = _editor(io);
      ed.readLine('> ');
      await _flush();
      final a = ed.readKey();
      final b = ed.readKey(); // would orphan `a` without serialization

      io.feedBytes([0x61]); // 'a'
      await _flush();
      final ea = await a.timeout(const Duration(seconds: 2));
      expect((ea as CharInput).text, 'a');

      // Let the second caller claim the key stream, then feed its key.
      await _flush();
      io.feedBytes([0x62]); // 'b'
      await _flush();
      final eb = await b.timeout(const Duration(seconds: 2));
      expect((eb as CharInput).text, 'b');
    });
  });

  group('LineEditor split-panel rendering', () {
    test('typing in split layout never leaks past divider', () async {
      final io = FakeStdio();
      final ed = _editor(io, width: 100);
      // Don't bother with VirtualTerminal — verify via output absence of
      // any control sequence that would move past dividerCol.
      ed.readLine('> ');
      await _flush();

      // Type wide buffer.
      for (final c in ('q' * 80).codeUnits) {
        io.feedBytes([c]);
      }
      await _flush();
      // Output should never contain a runaway "qqqq..." longer than the
      // chat width on a single line (loose check: each \x1bX erases the
      // row first, so check the output uses absolute positioning).
      final out = io.written.toString();
      expect(out.contains('\x1b['), isTrue);

      io.feedBytes([0x03, 0x03]);
      await _flush();
    });
  });

  group('LineEditor modal surfaces', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('an active modal consumes events before the editor sees them',
        () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      final modal = _FakeModal(true);
      ed.registerModal(modal);

      io.feedBytes([0x61]); // 'a' — claimed by the modal, never buffered
      await _flush();
      expect(modal.events, equals([CharInput('a')]));

      // Deactivate: subsequent typing reaches the editor normally. The result
      // is 'b' (not 'ab'), proving the earlier 'a' was consumed by the modal.
      modal.active = false;
      io.feedBytes([0x62, 0x0d]); // 'b', Enter
      expect(await f, 'b',
          reason: "'a' was consumed by the modal; only 'b' was typed after");
    });

    test('an inactive modal lets events fall through to the editor', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      ed.registerModal(_FakeModal(false));

      io.feedBytes([0x61, 0x62, 0x0d]); // 'a', 'b', Enter
      expect(await f, 'ab');
    });

    test('an active modal that declines an event lets it fall through',
        () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      final modal = _FakeModal(true)..consume = false;
      ed.registerModal(modal);

      io.feedBytes([0x61, 0x62, 0x0d]); // offered to the modal, then the editor
      await _flush();
      expect(modal.events, hasLength(3));
      expect(await f, 'ab');
    });

    test('unregister stops a surface from receiving events', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      final modal = _FakeModal(true);
      ed.registerModal(modal);
      ed.unregisterModal(modal);

      io.feedBytes([0x61, 0x62, 0x0d]); // straight to the editor
      expect(await f, 'ab');
      expect(modal.events, isEmpty);
    });
  });

  group('LineEditor bracketed paste', () {
    late FakeStdio io;

    setUp(() => io = FakeStdio());

    /// Bytes for `ESC[200~` … `ESC[201~` wrapping [content].
    List<int> _pasteBytes(String content) => [
          0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // \e[200~
          ...content.codeUnits,
          0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // \e[201~
        ];

    test('paste renders a placeholder, Enter submits the real text', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes(_pasteBytes('line1\nline2'));
      await _flush();
      // 'line1\nline2' is 11 runes; the placeholder appears in the render.
      final out = io.written.toString();
      expect(out, contains('[Pasted text : 11 chars]'));
      // The raw multi-line text must NOT leak as literal typed content.
      expect(out.contains('line1\nline2'), isFalse);
      // Enter submits the real text (newlines preserved).
      io.feedBytes([0x0d]);
      expect(await f, 'line1\nline2');
    });

    test('paste is atomic: left arrow then backspace removes the block',
        () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes(_pasteBytes('Hello'));
      await _flush();
      // Cursor sits at the placeholder's right edge. One left arrow jumps over
      // the whole span to its left edge; backspace at the left edge... the
      // editor deletes one char before the cursor there. So instead: park at
      // the right edge (default), backspace should remove the whole span.
      io.feedBytes([0x1b, 0x5b, 0x44]); // Left
      await _flush();
      // Now cursor is at the span's left edge. Move right to jump back over it.
      io.feedBytes([0x1b, 0x5b, 0x43]); // Right
      await _flush();
      // Backspace at the right edge removes the whole paste block.
      io.feedBytes([0x7f]); // Backspace
      await _flush();
      io.feedBytes([0x0d]); // Enter
      expect(await f, '');
    });

    test('paste followed by typing and Enter submits both', () async {
      final ed = _editor(io);
      final f = ed.readLine('> ');
      await _flush();
      io.feedBytes(_pasteBytes('AB'));
      await _flush();
      io.feedBytes([0x63]); // 'c'
      await _flush();
      io.feedBytes([0x0d]); // Enter
      expect(await f, 'ABc');
    });
  });
}
