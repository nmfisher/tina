import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/styled_text.dart';
import 'package:test/test.dart';

void main() {
  group('Theme.defaults', () {
    test('returns the shipped SGR values', () {
      const theme = Theme.defaults();
      expect(theme.chat.userBar, '7');
      expect(theme.chat.agentText, '39');
      expect(theme.border.focus, '36');
      expect(theme.border.selection, '33');
      expect(theme.border.busy.rail, '38;2;30;110;130');
      expect(theme.border.busy.head, '1;38;2;175;255;255');
      expect(theme.border.busy.railRgb, [30, 110, 130]);
      expect(theme.border.busy.headRgb, [175, 255, 255]);
      expect(theme.border.busy.tailLength, 7);
    });

    test('isDefault is true for the shipped theme', () {
      const theme = Theme.defaults();
      expect(theme.toMap(), isEmpty);
    });
  });

  group('Theme.light / Theme.dark', () {
    test('light uses black-on-bright bars and standard ANSI codes', () {
      const theme = Theme.light();
      expect(theme.chat.userBar, '97;40'); // bright white on black
      expect(theme.chat.agentText, '30'); // black
      expect(theme.chat.cyan, '36');
      expect(theme.border.focus, '36');
      expect(theme.hostMessage.user, '97;40');
    });

    test('dark uses bright bars and bright ANSI codes', () {
      const theme = Theme.dark();
      expect(theme.chat.userBar, '30;47'); // black on white
      expect(theme.chat.agentText, '97'); // bright white
      expect(theme.chat.cyan, '96'); // bright cyan
      expect(theme.border.focus, '96');
      expect(theme.hostMessage.user, '30;47');
    });
  });

  group('ChatTheme markdown styles (tin-g7rk)', () {
    test('all three variants ship the four markdown fields', () {
      for (final theme
          in const [Theme.defaults(), Theme.light(), Theme.dark()]) {
        expect(theme.chat.header, isNotEmpty);
        expect(theme.chat.inlineCode, isNotEmpty);
        expect(theme.chat.codeBlock, isNotEmpty);
        expect(theme.chat.link, isNotEmpty);
      }
    });

    test('every markdown code is inside the styled-run parser vocabulary', () {
      // The markdown renderer embeds these codes as inline SGR in chat rows;
      // applySgrCode silently drops anything outside its switch (notably
      // SGR 7, reverse video), which would render on ANSI but not notcurses.
      // A code that parses to the all-default state has been dropped.
      const names = ['defaults', 'light', 'dark'];
      const themes = [Theme.defaults(), Theme.light(), Theme.dark()];
      for (var i = 0; i < themes.length; i++) {
        for (final code in [
          themes[i].chat.header,
          themes[i].chat.inlineCode,
          themes[i].chat.link,
        ]) {
          final acc = SgrState();
          applySgrCode(code.split(';'), _NullSink(), acc);
          expect(
            acc.fg != null || acc.bg != null || acc.stylebits != 0,
            isTrue,
            reason: '$code from ${names[i]} parsed to the default state — '
                'applySgrCode dropped it',
          );
        }
      }
    });

    test('codeBlock sets a background so the region paints a solid bar', () {
      // The chat row's bar padding engages only for styles _hasBackground
      // recognises (40-47 / 100-107 / 48 / 7). A code block without one
      // would render as floating text instead of a bar.
      bool hasBackground(String style) {
        for (final code in style.split(';')) {
          final n = int.tryParse(code);
          if (n == null) continue;
          if ((n >= 40 && n <= 49) || (n >= 100 && n <= 107) || n == 7) {
            return true;
          }
        }
        return false;
      }

      for (final theme
          in const [Theme.defaults(), Theme.light(), Theme.dark()]) {
        expect(hasBackground(theme.chat.codeBlock), isTrue,
            reason: 'codeBlock must set a background colour');
      }
    });

    test('fromMap/toMap round-trips the markdown fields', () {
      const original = ChatTheme(
        header: '1;4',
        inlineCode: '97;100',
        codeBlock: '97;100',
        link: '4;96',
      );
      final map = original.toMap();
      expect(map, {
        'header': '1;4',
        'inline_code': '97;100',
        'code_block': '97;100',
        'link': '4;96',
      });
      final roundTrip = ChatTheme.fromMap(map);
      expect(roundTrip.header, '1;4');
      expect(roundTrip.inlineCode, '97;100');
      expect(roundTrip.codeBlock, '97;100');
      expect(roundTrip.link, '4;96');
    });
  });

  group('Theme.fromMap', () {
    test('overrides only supplied keys; missing keys fall back to defaults', () {
      final theme = Theme.fromMap({
        'chat': {'user_bar': '92;100'},
        'border': {'focus': '35'},
      });
      expect(theme.chat.userBar, '92;100');
      expect(theme.chat.agentText, '39'); // default
      expect(theme.border.focus, '35');
      expect(theme.border.selection, '33'); // default
      expect(theme.border.busy.rail, '38;2;30;110;130'); // default
    });

    test('null map returns defaults', () {
      final theme = Theme.fromMap(null);
      expect(theme, const Theme.defaults());
    });

    test('empty nested map returns defaults for that section', () {
      final theme = Theme.fromMap({
        'chat': {},
        'border': {'busy': {}},
      });
      expect(theme.chat.userBar, '7');
      expect(theme.border.busy.rail, '38;2;30;110;130');
      expect(theme.border.busy.headRgb, [175, 255, 255]);
    });
  });

  group('BusyBorderTheme RGB fallback', () {
    test('explicit rail_rgb/head_rgb are used', () {
      final theme = Theme.fromMap({
        'border': {
          'busy': {
            'rail': '38;2;1;2;3',
            'head': '1;38;2;4;5;6',
            'rail_rgb': [10, 20, 30],
            'head_rgb': [40, 50, 60],
          },
        },
      });
      expect(theme.border.busy.railRgb, [10, 20, 30]);
      expect(theme.border.busy.headRgb, [40, 50, 60]);
    });

    test('RGB is derived from SGR when explicit RGB is omitted', () {
      final theme = Theme.fromMap({
        'border': {
          'busy': {
            'rail': '38;2;11;22;33',
            'head': '1;48;2;44;55;66',
          },
        },
      });
      expect(theme.border.busy.railRgb, [11, 22, 33]);
      expect(theme.border.busy.headRgb, [44, 55, 66]);
    });

    test('falls back to defaults when SGR contains no truecolor triple', () {
      final theme = Theme.fromMap({
        'border': {
          'busy': {
            'rail': '36',
            'head': '1;37',
          },
        },
      });
      expect(theme.border.busy.railRgb, [30, 110, 130]);
      expect(theme.border.busy.headRgb, [175, 255, 255]);
    });
  });

  group('Theme.toMap / round-trip', () {
    test('toMap emits only non-default values', () {
      const theme = Theme(
        chat: ChatTheme(userBar: '92;100'),
        border: BorderTheme(
          focus: '35',
          busy: BusyBorderTheme(tailLength: 5),
        ),
      );
      final map = theme.toMap();
      expect(map['chat'], {'user_bar': '92;100'});
      expect(map['border'], {
        'focus': '35',
        'busy': {'tail_length': 5},
      });
      expect(map.keys, contains('chat'));
      expect(map.keys, contains('border'));
      expect(map.keys, isNot(contains('menu')));
    });

    test('round-trip fromMap/toMap preserves overrides', () {
      const original = Theme(
        chat: ChatTheme(userBar: '92;100', agentText: '34'),
        border: BorderTheme(
          focus: '35',
          busy: BusyBorderTheme(
            rail: '38;2;11;22;33',
            head: '1;38;2;44;55;66',
            tailLength: 5,
          ),
        ),
        menu: MenuTheme(barHighlight: '1;37'),
      );
      final map = original.toMap();
      final roundTrip = Theme.fromMap(map);
      expect(roundTrip.chat.userBar, '92;100');
      expect(roundTrip.chat.agentText, '34');
      expect(roundTrip.border.focus, '35');
      expect(roundTrip.border.busy.rail, '38;2;11;22;33');
      expect(roundTrip.border.busy.head, '1;38;2;44;55;66');
      expect(roundTrip.border.busy.tailLength, 5);
      expect(roundTrip.menu.barHighlight, '1;37');
    });
  });

  group('HostMessageTheme', () {
    test('normal is null by default (passthrough, no SGR)', () {
      const theme = HostMessageTheme();
      expect(theme.normal, isNull);
      expect(theme.toMap(), isEmpty);
    });

    test('normal can be set to a non-empty SGR', () {
      const theme = HostMessageTheme(normal: '90');
      expect(theme.toMap(), {'normal': '90'});
      final fromMap = HostMessageTheme.fromMap({'normal': '90'});
      expect(fromMap.normal, '90');
    });

    test('empty string normal is treated as null', () {
      final fromMap = HostMessageTheme.fromMap({'normal': ''});
      expect(fromMap.normal, isNull);
    });
  });

  // Theme-change invalidation (builds a Screen, so kept in this screen-aware
  // group rather than the pure-Theme groups above).
  themeChangeInvalidationTests();
}

/// A minimal [Stdio] double so this test needs no cross-file fixture. We assert
/// on the chat region's retained paint state, not the rendered byte stream.
class _TThemeStdio implements Stdio {
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  void write(String s) {}
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}

final void Function() themeChangeInvalidationTests = () {
  group('Screen.setTheme invalidation', () {
    test('clears retained paint snapshots so new-theme SGR re-emits', () {
      final io = _TThemeStdio();
      final layout = ScreenLayout.fromSize(80, 24);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);

      // Render a styled (reverse-video bar) row so the chat region holds a
      // painted snapshot that embeds the old theme's SGR. The ansi backend
      // paints synchronously inside screen.frame(), so a redrawFrame() now
      // populates the paintedText snapshot.
      screen.chat.beginStyle('7');
      screen.chat.write('hello');
      screen.chat.endStyle();
      screen.redrawFrame();
      expect(screen.chat.debugPaintedText(0), isNotNull,
          reason: 'styled row should have retained a paint snapshot');

      final versionBefore = gThemeStyleVersion;

      // Change the theme → must bump the style version, clear the parse
      // cache, and drop the retained snapshot.
      screen.setTheme(Theme.dark());

      expect(gThemeStyleVersion, greaterThan(versionBefore),
          reason: 'setTheme must bump the theme-style version');
      expect(styledRunCache.length, 0,
          reason: 'setTheme must clear the parse cache');
      expect(screen.chat.debugPaintedText(0), isNull,
          reason: 'setTheme must clear retained paint snapshots so the new '
              'theme\'s SGR re-emits');
    });
  });
};

/// A [StyledStyleSink] that records nothing — the vocabulary test only cares
/// whether `applySgrCode` *accepts* each code, not what setters it issues.
class _NullSink implements StyledStyleSink {
  @override
  void setStyles(int stylebits) {}
  @override
  void setFgRGB(int hex) {}
  @override
  void setBgRGB(int hex) {}
  @override
  void setFgDefault() {}
  @override
  void setBgDefault() {}
}
