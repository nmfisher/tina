// Tab completion in `!` mode at the editor level: Tab on a shell passthrough
// line opens the bang picker over the word under the cursor (command source
// for the first word, path source for later words), acceptance replaces
// exactly that word plus a trailing space, and Enter accepts without
// submitting. The picker machinery itself is completion_picker_test's; the
// sources are fakes here — the real ones live in tina_tui.
library;

import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Records every query; answers with [results].
final class _RecordingSource implements CompletionProvider {
  final List<String> results;
  final queries = <String>[];
  _RecordingSource(this.results);

  @override
  Future<List<String>> complete(String query) async {
    queries.add(query);
    return results;
  }
}

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

(LineEditor, FakeStdio) _editor(BangCompletion? bang) {
  final io = FakeStdio();
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.yes,
  );
  final ed = LineEditor(
    screen: screen,
    escapeTimeout: Duration.zero,
  )..bangCompletion = bang;
  return (ed, io);
}

void main() {
  late _RecordingSource commands;
  late _RecordingSource paths;

  setUp(() {
    commands = _RecordingSource(const ['!git', '!grep']);
    paths = _RecordingSource(const ['src/foo.dart', 'src/bar.dart']);
  });

  test('Tab on the first word completes command names, accept keeps the !',
      () async {
    final (ed, io) = _editor(BangCompletion(commands: commands, paths: paths));
    addTearDown(ed.close);
    var submitted = false;
    final reading = ed.readLine('> ').then((v) {
      submitted = true;
      return v;
    });
    await _flush();
    io.feedBytes('!gi'.codeUnits);
    await _flush();
    io.feedBytes([0x09]); // Tab
    await _flush();
    expect(ed.isCompleting, isTrue, reason: 'Tab must open the bang picker');
    expect(commands.queries, ['gi'],
        reason: 'the command-word source sees the word after the !');

    io.feedBytes([0x09]); // Tab again: accept the selection
    await _flush();
    expect(ed.editState.buffer, '!git ',
        reason: 'acceptance replaces !gi with the candidate plus a space');
    expect(submitted, isFalse,
        reason: 'Enter/Tab in the bang picker must not submit the line');

    io.feedBytes([0x0d]);
    await _flush();
    expect(await reading, '!git ');
  });

  test('Tab on a later word completes paths over that word only', () async {
    final (ed, io) = _editor(BangCompletion(commands: commands, paths: paths));
    addTearDown(ed.close);
    ed.readLine('> ');
    await _flush();
    io.feedBytes('!cat src/f'.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(paths.queries, ['src/f'],
        reason: 'the path source sees the word under the cursor');
    expect(commands.queries, isEmpty);

    io.feedBytes([0x0d]); // Enter accepts the selection
    await _flush();
    expect(ed.editState.buffer, '!cat src/foo.dart ',
        reason: 'acceptance replaces only the word under the cursor');
  });

  test('a quoted word queries the source with its raw text', () async {
    final (ed, io) = _editor(BangCompletion(commands: commands, paths: paths));
    addTearDown(ed.close);
    ed.readLine('> ');
    await _flush();
    io.feedBytes("!cat 'src/f".codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(paths.queries, ["'src/f"],
        reason: 'quote handling belongs to the source, not the editor');
  });

  test('Tab after a space completes an empty path word and keeps the space',
      () async {
    final (ed, io) = _editor(BangCompletion(commands: commands, paths: paths));
    addTearDown(ed.close);
    ed.readLine('> ');
    await _flush();
    io.feedBytes('!cat '.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(paths.queries, ['']);

    io.feedBytes([0x0d]);
    await _flush();
    expect(ed.editState.buffer, '!cat src/foo.dart ',
        reason: 'the anchor consumes the separator; the suffix restores it');
  });

  test('the trigger matches only leading-bang lines', () async {
    final (ed, io) = _editor(BangCompletion(commands: commands, paths: paths));
    addTearDown(ed.close);
    ed.readLine('> ');
    await _flush();

    io.feedBytes('text !gi'.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(ed.isCompleting, isFalse,
        reason: 'a bang mid-line is ordinary input');

    io.feedBytes([0x15]); // ctrl-U: clear the line
    await _flush();
    io.feedBytes('  !gi'.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(ed.isCompleting, isTrue,
        reason: 'leading whitespace still routes to the shell');
    expect(commands.queries, ['gi']);
    io.feedBytes([0x1b]); // Esc: dismiss
    await _flush();

    io.feedBytes([0x15]);
    await _flush();
    io.feedBytes('!!'.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(ed.isCompleting, isTrue,
        reason: '!! submits as a shell line; completion follows');
    expect(commands.queries.last, '!',
        reason: 'the word after the bang is ! for a double bang');
  });

  test('null bang completion leaves Tab inert on bang lines', () async {
    final (ed, io) = _editor(null);
    addTearDown(ed.close);
    ed.readLine('> ');
    await _flush();
    io.feedBytes('!gi'.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    expect(ed.isCompleting, isFalse);
    expect(ed.editState.buffer, '!gi');
  });

  test('typing narrows an open bang picker through the path source',
      () async {
    final (ed, io) = _editor(BangCompletion(commands: commands, paths: paths));
    addTearDown(ed.close);
    ed.readLine('> ');
    await _flush();
    io.feedBytes('!cat s'.codeUnits);
    await _flush();
    io.feedBytes([0x09]);
    await _flush();
    io.feedBytes('r'.codeUnits); // keep typing: query becomes sr
    await _flush();
    expect(paths.queries, ['s', 'sr'],
        reason: 'an open picker refreshes on every keystroke');
    io.feedBytes([0x1b]);
    await _flush();
    expect(ed.editState.buffer, '!cat sr');
  });
}
