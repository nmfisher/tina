import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/src/backend/canvas_style.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:tina_console/src/styled_text.dart';

import 'notcurses_backend_platform_test.dart' show RecordingPlatform;
import 'stdio_fake.dart';

// Interpret emitted styles at each printable span / erase, rather than just
// checking that a background code appeared somewhere in the output. Null
// means the terminal's original color, which must not leak into explicit themes.
List<({String text, int? fg, int? bg})> paints(String output) {
  final state = SgrState();
  final result = <({String text, int? fg, int? bg})>[];
  for (final match in RegExp(
          r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[78]|[^\x1b]+')
      .allMatches(output)) {
    final token = match[0]!;
    if (token.startsWith('\x1b[') && token.endsWith('m')) {
      applySgrCode(
          token.substring(2, token.length - 1).split(';'), _Sink(), state);
    } else if (!token.startsWith('\x1b') || token.endsWith('X')) {
      result.add((text: token, fg: state.fg, bg: state.bg));
    }
  }
  return result;
}

class _Sink implements StyledStyleSink {
  @override
  void setFgDefault() {}
  @override
  void setBgDefault() {}
  @override
  void setFgRGB(int hex) {}
  @override
  void setBgRGB(int hex) {}
  @override
  void setStyles(int bits) {}
}

void main() {
  for (final (name, theme, background) in [
    ('dark', const Theme.dark(), 0x1c1c1c),
    ('light', const Theme.light(), 0xeeeeee),
  ]) {
    test('$name covers the screen, input, overlays, erases and resized space',
        () {
      final io = FakeStdio();
      final screen = Screen(
          io: io,
          ansi: AnsiCapable.yes,
          theme: theme,
          layout: ScreenLayout.fromSize(80, 10, split: false));
      addTearDown(() {
        screen.dispose();
        io.close();
      });
      screen.enterAltScreen();
      final initial = paints(io.written.toString());
      expect(initial.where((p) => p.text == '\x1b[80X'), hasLength(10),
          reason:
              'every row, including unused space, has an application background');
      screen.chat.writeln('plain text');
      screen.input.render(
          prompt: screen.colorize('2', 'model > '), buffer: 'draft', cursor: 5);
      final overlay =
          OverlayRegion(screen, Rect(row: 4, col: 0, width: 30, height: 2));
      overlay.show([screen.colorize('1', 'Question'), '[x] Yes   [ ] No']);
      overlay.hide();
      overlay.dispose();
      screen.input.repaint();
      screen.resize(ScreenLayout.fromSize(100, 24, split: false));
      final painted = paints(io.written.toString());
      expect(painted.where((p) => p.text == '\x1b[100X').length,
          greaterThanOrEqualTo(24));
      for (final p in painted) {
        expect(p.bg, background, reason: 'incorrect background for ${p.text}');
      }
      expect(painted.any((p) => p.text.contains('draft')), true);
      io.written.clear();
      screen.leaveAltScreen();
      expect(io.written.toString(), contains('\x1b[0m\x1b[?1049l'));
      expect(io.written.toString(), contains('\x1b]112\x07'),
          reason: 'the shell regains its terminal-profile cursor color');
      expect(io.written.toString(), isNot(contains('\x1b]4;')),
          reason: 'application themes never modify the terminal palette');
    });
  }

  test('resets restore the canvas while explicit colors survive', () {
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final backend = AnsiBackend(io: io, ansi: AnsiCapable.yes)
      ..setCanvasStyle(foreground: '38;5;252', background: '48;5;234');
    backend.writeText('plain\x1b[31mred\x1b[0;1mbold\x1b[mreset'
        '\x1b[48;2;0;39;49mcustom\x1b[49mcanvas'
        '\x1b[38;5;39mindexed\x1b[39mforeground');
    backend.flush();
    final spans = {for (final p in paints(io.written.toString())) p.text: p};
    for (final key in [
      'plain',
      'red',
      'bold',
      'reset',
      'canvas',
      'indexed',
      'foreground'
    ]) {
      expect(spans[key]!.bg, 0x1c1c1c, reason: key);
    }
    expect(spans['custom']!.bg, 0x002731);
    expect(spans['red']!.fg, 0xcd0000);
    expect(spans['indexed']!.fg, 0x00afff);
    expect(spans['foreground']!.fg, 0xd0d0d0);
  });

  test('default and NO_COLOR preserve unthemed output', () {
    const text = 'text\x1b[0m';
    expect(const CanvasStyle().apply(text), text);
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final backend = AnsiBackend(io: io, ansi: AnsiCapable.no)
      ..setCanvasStyle(foreground: '37', background: '40');
    backend.writeText(backend.colorize('31', 'plain'));
    backend.leaveAltScreen();
    backend.flush();
    expect(io.written.toString(), 'plain\x1b[?1000l\x1b[?1006l\x1b[?1049l');
  });

  test('switching back to terminal defaults clears the application canvas', () {
    final io = FakeStdio();
    final screen = Screen(
        io: io,
        ansi: AnsiCapable.yes,
        theme: const Theme.dark(),
        layout: ScreenLayout.fromSize(80, 10));
    addTearDown(() {
      screen.dispose();
      io.close();
    });
    screen.enterAltScreen();
    io.written.clear();
    screen.setTheme(const Theme.defaults());
    screen.redrawFrame();
    screen.input.render(prompt: '> ', buffer: '', cursor: 0);
    for (final paint in paints(io.written.toString())) {
      expect(paint.bg, isNull);
    }
    screen.leaveAltScreen();
  });

  test('native backend applies canvas to resets and blank cells', () {
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final platform = RecordingPlatform();
    final backend = NotcursesBackend.forTesting(io: io, platform: platform)
      ..setCanvasStyle(foreground: '38;5;252', background: '48;5;234');
    addTearDown(backend.leaveAltScreen);
    platform.calls.clear();
    backend.writeText('first\x1b[0msecond');
    backend.eraseCells(2, 0, 4);
    int? background;
    var writes = 0;
    for (final call in platform.calls) {
      if (call == 'setBgDefault') background = null;
      if (call.startsWith('setBgRGB(')) {
        background = int.parse(call.substring(9, call.length - 1));
      }
      if (call.startsWith('putStrYX(')) {
        expect(background, 0x1c1c1c);
        writes++;
      }
    }
    expect(writes, greaterThanOrEqualTo(2));
  });

  test('hardware cursor follows dark, light, custom and default themes', () {
    for (final native in [false, true]) {
      final io = FakeStdio();
      final platform = RecordingPlatform();
      final TerminalBackend backend;
      if (native) {
        backend = NotcursesBackend.forTesting(io: io, platform: platform);
      } else {
        backend = AnsiBackend(io: io, ansi: AnsiCapable.yes);
      }
      final screen = Screen.withBackend(
          io: io,
          backend: backend,
          ansi: AnsiCapable.yes,
          theme: const Theme.dark(),
          layout: ScreenLayout.fromSize(80, 10));
      addTearDown(() {
        screen.dispose();
        io.close();
      });
      screen.enterAltScreen();
      screen.setTheme(const Theme.light());
      screen.setTheme(const Theme(
          canvas:
              CanvasTheme(foreground: '38;2;20;210;180', background: '40')));
      screen.setTheme(const Theme.defaults());
      screen.setTheme(const Theme.dark());
      screen.leaveAltScreen();
      final output =
          native ? platform.rawTtyWrites.join() : io.written.toString();
      final colors = RegExp(r'\x1b\](?:12;#[a-f0-9]{6}|112)\x07')
          .allMatches(output)
          .map((m) => m[0]!)
          .toList();
      expect(
          colors,
          [
            '\x1b]12;#d0d0d0\x07',
            '\x1b]12;#080808\x07',
            '\x1b]12;#14d2b4\x07',
            '\x1b]112\x07',
            '\x1b]12;#d0d0d0\x07',
            '\x1b]112\x07',
          ],
          reason: native ? 'native terminal' : 'ANSI terminal');
      expect(output, isNot(contains('\x1b]4;')));
      if (native) expect(platform.calls.last, 'stop');
    }
  });
}
