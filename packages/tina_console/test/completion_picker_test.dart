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

void main() {
  group('CompletionPicker logic', () {
    late FakeStdio io;
    late Screen screen;
    late CompletionPicker picker;

    setUp(() {
      io = FakeStdio();
      screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 30),
        ansi: AnsiCapable.yes,
      );
      screen.redrawFrame();
      io.written.clear();
      picker = CompletionPicker(screen);
    });

    tearDown(() => picker.dispose());

    test('shouldTrigger requires provider, @ char, and word boundary', () {
      expect(picker.shouldTrigger(0x40, '', 0), isFalse,
          reason: 'no provider yet');
      picker.provider = _StaticProvider(['a']);
      expect(picker.shouldTrigger(0x40, '', 0), isTrue);
      expect(picker.shouldTrigger(0x40, 'foo', 3), isFalse,
          reason: 'cursor mid-word');
      expect(picker.shouldTrigger(0x40, 'foo ', 4), isTrue,
          reason: 'cursor after space');
      expect(picker.shouldTrigger(0x41, '', 0), isFalse,
          reason: 'wrong key');
    });

    test('open and closeState toggle active', () {
      picker.provider = _StaticProvider(['a']);
      expect(picker.isActive, isFalse);
      picker.open(0);
      expect(picker.isActive, isTrue);
      picker.closeState();
      expect(picker.isActive, isFalse);
    });

    test('refresh resolves results and renders', () async {
      picker.provider = _StaticProvider(['alpha', 'beta']);
      picker.open(0);
      await picker.refresh('@', 1);
      // Output should mention alpha and beta.
      final out = io.written.toString();
      expect(out.contains('alpha'), isTrue);
      expect(out.contains('beta'), isTrue);
    });

    test('navigate selects different item', () async {
      picker.provider = _StaticProvider(['x', 'y', 'z']);
      picker.open(0);
      await picker.refresh('@', 1);
      picker.navigateDown();
      final accepted = picker.accept('@', 1);
      expect(accepted?.text, '@y');
    });

    test('accept returns replacement range', () async {
      picker.provider = _StaticProvider(['lib/main.dart']);
      picker.open(0);
      await picker.refresh('@', 1);
      final r = picker.accept('@', 1);
      expect(r?.start, 0);
      expect(r?.end, 1);
      expect(r?.text, '@lib/main.dart');
    });

    test('onError fires when provider throws', () async {
      Object? caught;
      picker = CompletionPicker(screen, onError: (e, _) => caught = e);
      picker.provider = _ThrowingProvider();
      picker.open(0);
      await picker.refresh('@', 1);
      expect(caught, isStateError);
    });

    test('stale refresh is ignored when generation changed', () async {
      picker.provider = _StaticProvider(['old']);
      picker.open(0);
      final f1 = picker.refresh('@', 1);
      picker.closeState();
      final r = await f1;
      expect(r, isFalse);
    });

    test('queryFromBuffer extracts text after anchor', () {
      picker.provider = _StaticProvider([]);
      picker.open(3); // '@' at idx 3 in 'hi @foo'
      expect(picker.queryFromBuffer('hi @foo', 7), 'foo');
    });
  });

  group('CompletionPicker config knobs (command palette)', () {
    late FakeStdio io;
    late Screen screen;

    setUp(() {
      io = FakeStdio();
      screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 30),
        ansi: AnsiCapable.yes,
      );
      screen.redrawFrame();
      io.written.clear();
    });

    /// A `/` picker: opens only at the start of an empty line, accepts the
    /// result verbatim (results already carry the slash) plus a trailing space.
    CompletionPicker commandPicker() => CompletionPicker.commandPicker(
          screen,
          provider: _StaticProvider(['/help', '/exit', '/clear']),
        );

    test('defaults preserve the @ picker exactly', () async {
      final at = CompletionPicker(screen, provider: _StaticProvider(['p.dart']));
      expect(at.shouldTrigger(0x40, '', 0), isTrue);
      expect(at.shouldTrigger(0x40, 'foo ', 4), isTrue);
      expect(at.shouldTrigger(0x40, 'foo', 3), isFalse);
      at.open(0);
      await at.refresh('@', 1);
      expect(at.accept('@', 1)?.text, '@p.dart');
      at.dispose();
    });

    test('/ trigger fires only at the start of an empty line', () {
      final p = commandPicker();
      expect(p.shouldTrigger(0x2f, '', 0), isTrue,
          reason: 'empty buffer, column 0');
      expect(p.shouldTrigger(0x2f, 'hi', 2), isFalse, reason: 'not at the start');
      expect(p.shouldTrigger(0x2f, 'hi ', 3), isFalse,
          reason: 'after whitespace but not at the start');
      expect(p.shouldTrigger(0x40, '', 0), isFalse, reason: 'wrong trigger');
      p.dispose();
    });

    test('accept yields the command plus a trailing space (no double slash)',
        () async {
      final p = commandPicker();
      p.open(0);
      await p.refresh('/', 1);
      final r = p.accept('/', 1);
      expect(r?.start, 0);
      expect(r?.end, 1);
      expect(r?.text, '/help ');
      p.dispose();
    });

    test('every result is reachable when maxRows exceeds the result count',
        () async {
      // 13 commands — more than the default maxRows of 8, so a low maxRows
      // would strand items 8..12 (navigation wraps over min(count, maxRows)).
      final commands = [for (var i = 0; i < 13; i++) '/cmd$i'];
      final p = CompletionPicker(
        screen,
        trigger: 0x2f,
        shouldOpen: (_, __) => true,
        prependTriggerOnAccept: false,
        maxRows: 32,
        provider: _StaticProvider(commands),
      );
      p.open(0);
      await p.refresh('/', 1);
      for (var i = 0; i < 12; i++) {
        p.navigateDown();
      }
      expect(p.accept('/', 1)?.text, commands.last,
          reason: 'reached item 12 — beyond the default 8-row cap');
      p.navigateDown(); // wraps back to the first
      expect(p.accept('/', 1)?.text, commands.first);
      p.dispose();
    });
  });
}
