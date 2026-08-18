import 'package:test/test.dart';

import 'package:tina_console/src/term_width.dart';

/// The width table behind every column budget in the chat emit path
/// (tin-q4vz). The doctrine is "err high, never low": over-counting costs a
/// column at the right edge, under-counting wraps a row past the plane edge
/// and onto the next screen row. These cases pin the runes that actually
/// appear in the paste corpus (CJK, flag/family emoji, VS16, ✓) plus the
/// joiner/selector edge cases where a naive wcwidth would under-count.
void main() {
  group('runeWidth', () {
    test('ASCII and Latin-1 are 1', () {
      expect(runeWidth(0x41), 1);
      expect(runeWidth(0x20), 1);
      expect(runeWidth(0xb7), 1); // · (the corpus separator)
      expect(runeWidth(0x2713), 1); // ✓
    });

    test('BMP CJK is 2', () {
      expect(runeWidth(0x6f22), 2); // 漢
      expect(runeWidth(0x5b57), 2); // 字
      expect(runeWidth(0x30c6), 2); // テ
      expect(runeWidth(0xff21), 2); // fullwidth Ａ
    });

    test('astral code points are 2 (emoji-wide; narrow ones err high)', () {
      expect(runeWidth(0x1f3f3), 2); // 🏳
      expect(runeWidth(0x1f308), 2); // 🌈
      expect(runeWidth(0x1d54f), 2); // 𝕏 — genuinely narrow; errs high by design
    });

    test('VS16 advances a cell so pictographic+VS16 errs high', () {
      expect(runeWidth(0xfe0f), 1);
      expect(runeWidth(0xfe0e), 0); // VS15 does not
    });

    test('ZWJ advances a cell (tmux lays each cluster member out)', () {
      // Measured live in tin-q4vz hunt 2: tmux gives the joiner its own
      // cell. Counting it 0 under-counts cluster-heavy rows and wraps them.
      expect(runeWidth(0x200d), 1);
      expect(runeWidth(0x200c), 0); // ZWNJ is still invisible
    });

    test('combining marks are 0', () {
      expect(runeWidth(0x0301), 0); // combining acute
      expect(runeWidth(0x0591), 0); // Hebrew accent
    });

    test('unpaired surrogates count 1, never 0', () {
      expect(runeWidth(0xd83c), 1);
      expect(runeWidth(0xdff8), 1);
    });
  });

  group('plainWidth', () {
    test('the corpus wide line budgets at terminal cells', () {
      // 漢字テスト混合 = 7 wide glyphs = 14; ' · ' = 3; 'emoji: ' = 7;
      // ✓ = 1 → the plain prefix of the corpus's CJK line.
      expect(plainWidth('漢字テスト混合 · emoji: ✓'), 14 + 3 + 7 + 1);
    });

    test('a ZWJ family budgets 11 — every member glyph gets a cell', () {
      // 4 people × 2 + 3 joiners × 1.
      expect(plainWidth('👨‍👩‍👧‍👦'), 11);
    });

    test('a flag+rainbow cluster with VS16 budgets 6', () {
      // 🏳 (2) + VS16 (1) + ZWJ (1) + 🌈 (2).
      expect(plainWidth('🏳️‍🌈'), 6);
    });

    test('plain ASCII is its own length', () {
      expect(plainWidth('long-token: '), 12);
    });
  });

  group('code-point decoding', () {
    test('runeSizeAt never splits a surrogate pair', () {
      const s = 'a漢🏳';
      expect(runeSizeAt(s, 0), 1); // 'a'
      expect(runeSizeAt(s, 1), 1); // 漢 (BMP)
      expect(runeSizeAt(s, 2), 2); // 🏳 lead + trail
      expect(runeSizeAt(s, 3), 1); // trail surrogate alone → 1
    });

    test('codePointAt decodes pairs and passes BMP/lone units through', () {
      const s = '漢🏳';
      expect(codePointAt(s, 0), 0x6f22);
      expect(codePointAt(s, 1), 0x1f3f3); // lead+trail decode to the pair
      expect(codePointAt(s, 2), 0xdff3); // lone trail decodes to itself
    });
  });
}
