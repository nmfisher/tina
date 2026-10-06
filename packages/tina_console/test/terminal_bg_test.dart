import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/src/terminal_bg.dart';

Future<TerminalBg> probeOnce(String reply) async {
  final controller = StreamController<List<int>>(sync: true);
  final probe = probeTerminalBg(probeStdin: controller.stream);
  controller.add(reply.codeUnits);
  return probe;
}

void main() {
  group('OSC 11 background probe', () {
    test('classic semicolon form (xterm, GNOME Terminal)', () async {
      expect(
          await probeOnce('\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\'),
          TerminalBg.dark,
          reason: 'luminance of #1c1c1c is far below the threshold');
    });

    test('colon form (kitty, WezTerm, Ghostty, foot, newer VTE)', () async {
      // ITU-T T.416 parameter separator: the same reply shape the reply
      // guard's probe once failed to recognize (tin first-run dead keys).
      expect(await probeOnce('\x1b]11:rgb:ffff/ffff/ffff\x1b\\'),
          TerminalBg.light);
      expect(
          await probeOnce('\x1b]11:rgb:0000/0000/0000\x1b\\'), TerminalBg.dark);
    });

    test('semicolon + hash-hex form', () async {
      expect(await probeOnce('\x1b]11;#ffffff\x07'), TerminalBg.light);
    });

    test('unparseable reply degrades to unknown', () async {
      expect(
          await probeOnce('\x1b]11;nonsense\x1b\\'), TerminalBg.unknown);
    });

    test('silence times out to unknown', () async {
      // Never complete the stream: the probe must hit its own timeout
      // rather than hang on a mute terminal.
      final controller = StreamController<List<int>>(sync: true);
      final bg = await probeTerminalBg(
          timeout: const Duration(milliseconds: 20),
          probeStdin: controller.stream);
      expect(bg, TerminalBg.unknown);
      await controller.close();
    });
  });

  group('background classification', () {
    test('luminance threshold follows BT.601', () {
      expect(bgFromRgb(0, 0, 0), TerminalBg.dark);
      expect(bgFromRgb(255, 255, 255), TerminalBg.light);
      // 0.299*128 ≈ 38 — dark; 0.587*255 ≈ 150 — light.
      expect(bgFromRgb(128, 0, 0), TerminalBg.dark);
      expect(bgFromRgb(0, 255, 0), TerminalBg.light);
    });
  });
}
