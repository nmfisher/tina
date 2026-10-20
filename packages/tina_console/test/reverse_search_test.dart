import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Reverse-incremental-search (readline Ctrl-R style): Ctrl+R opens a search
/// prompt over the editor's history, typing narrows to the most recent line
/// containing the query, Ctrl+R finds older matches, Enter accepts the match
/// into the buffer, and Esc/Ctrl+C cancels back to the draft.
void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;

  setUp(() {
    io = FakeStdio();
    screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    // escapeTimeout zero delivers ESC on the next microtask, so a standalone
    // Esc resolves immediately under the fake input stream.
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  });

  LineEditor withHistory(List<String> history) {
    editor.restoreHistory(history);
    return editor;
  }

  Future<void> flush() async {
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
    await Future<void>.delayed(Duration.zero);
  }

  String revPrompt(String q) => '(reverse-i-search)\\`$q\': ';
  String failedPrompt(String q) => '(failed reverse-i-search)\\`$q\': ';

  test('ctrl+r opens the search prompt over an empty draft', () async {
    withHistory(['ls -la', 'git status', 'dart test']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12]); // Ctrl+R
    await flush();
    expect(screen.input.prompt, revPrompt(''));
    expect(screen.input.buffer, '');
    // Enter with no query cancels to the (empty) draft; a second Enter submits.
    io.feedBytes([0x0d, 0x0d]);
    expect(await f, '');
  });

  test('typing narrows to the most recent match; Enter accepts into the buffer',
      () async {
    withHistory(['ls -la', 'git status', 'dart test']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12]); // Ctrl+R
    await flush();
    io.feedBytes('g'.codeUnits);
    await flush();
    expect(screen.input.prompt, revPrompt('g'));
    expect(screen.input.buffer, 'git status');
    io.feedBytes('i'.codeUnits);
    await flush();
    expect(screen.input.buffer, 'git status');
    // Enter accepts the match into the buffer (no submit yet).
    io.feedBytes([0x0d]);
    await flush();
    expect(screen.input.prompt, '> ');
    expect(screen.input.buffer, 'git status');
    // A second Enter submits the accepted line.
    io.feedBytes([0x0d]);
    expect(await f, 'git status');
  });

  test('ctrl+r again cycles to older matches, then reports failure', () async {
    withHistory(['ls -la', 'git status', 'git add .']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12]);
    await flush();
    io.feedBytes('git'.codeUnits);
    await flush();
    expect(screen.input.buffer, 'git add .');
    io.feedBytes([0x12]); // next older match
    await flush();
    expect(screen.input.buffer, 'git status');
    io.feedBytes([0x12]); // no older match remains
    await flush();
    expect(screen.input.prompt, failedPrompt('git'));
    expect(screen.input.buffer, '');
    io.feedBytes([0x1b]); // cancel
    await flush();
    io.feedBytes([0x0d]); // submit the empty draft
    expect(await f, '');
  });

  test('backspace edits the query and re-searches', () async {
    withHistory(['go build', 'go vet', 'ripgrep']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12]); // Ctrl+R
    await flush();
    io.feedBytes('go'.codeUnits);
    await flush();
    expect(screen.input.buffer, 'go vet');
    io.feedBytes([0x7f]); // backspace -> query "g"
    await flush();
    expect(screen.input.prompt, revPrompt('g'));
    expect(screen.input.buffer, 'ripgrep');
    io.feedBytes([0x7f]); // backspace to empty query cancels
    await flush();
    expect(screen.input.prompt, '> ');
    expect(screen.input.buffer, '');
    io.feedBytes([0x0d]);
    expect(await f, '');
  });

  test('esc cancels the search and restores the draft', () async {
    withHistory(['ls', 'git status']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes('hello'.codeUnits);
    await flush();
    expect(screen.input.buffer, 'hello');
    io.feedBytes([0x12]); // Ctrl+R
    await flush();
    io.feedBytes('g'.codeUnits);
    await flush();
    expect(screen.input.buffer, 'git status');
    io.feedBytes([0x1b]); // Esc cancels
    await flush();
    expect(screen.input.prompt, '> ');
    expect(screen.input.buffer, 'hello');
    io.feedBytes([0x0d]);
    expect(await f, 'hello');
  });

  test('ctrl+c during the search cancels and restores the draft', () async {
    withHistory(['ls', 'git status']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes('draft'.codeUnits);
    await flush();
    io.feedBytes([0x12]); // Ctrl+R
    await flush();
    io.feedBytes('g'.codeUnits);
    await flush();
    io.feedBytes([0x03]); // Ctrl+C
    await flush();
    expect(screen.input.prompt, '> ');
    expect(screen.input.buffer, 'draft');
    io.feedBytes([0x0d]);
    expect(await f, 'draft');
  });

  test('no match shows the failed indicator and an empty buffer', () async {
    withHistory(['ls', 'git status']);
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12]);
    await flush();
    io.feedBytes('zzz'.codeUnits);
    await flush();
    expect(screen.input.prompt, failedPrompt('zzz'));
    expect(screen.input.buffer, '');
    io.feedBytes([0x0d, 0x0d]); // accept (no match -> draft) then submit
    expect(await f, '');
  });

  test('ctrl+r with empty history opens the prompt without crashing', () async {
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12]);
    await flush();
    expect(screen.input.prompt, revPrompt(''));
    io.feedBytes('x'.codeUnits);
    await flush();
    expect(screen.input.prompt, failedPrompt('x'));
    io.feedBytes([0x1b]); // cancel
    await flush();
    io.feedBytes([0x0d]); // then submit empty
    expect(await f, '');
  });

  test('a configured onRawView hook still takes precedence over search',
      () async {
    withHistory(['git status']);
    var fired = 0;
    editor.onRawView = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12, 0x0d]); // Ctrl+R then Enter
    expect(await f, '');
    expect(fired, 1);
    expect(screen.input.prompt, '> ', reason: 'search did not open');
  });
}
