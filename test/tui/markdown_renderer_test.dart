import 'package:tina/tui/markdown_renderer.dart';
import 'package:test/test.dart';

import '../helpers/markdown_line_matchers.dart';

/// The shipped default style (matches ChatTheme defaults / MarkdownStyle()).
const style = MarkdownStyle();

void main() {
  group('renderMarkdown — blocks', () {
    test('ATX headers drop the hashes and take the header style', () {
      final lines = renderMarkdown('## Done', style);
      expect(lines, hasRuns([
        [styledRun('Done', style.header)],
      ]));
    });

    test('header levels 1–6 all render', () {
      for (final hashes in ['# ', '## ', '### ', '#### ', '##### ', '###### ']) {
        final lines = renderMarkdown('${hashes}Title', style);
        expect(lines.single.runs.single.code, style.header,
            reason: 'header "$hashes" must carry the header style');
        expect(lines.single.runs.single.text, 'Title');
      }
    });

    test('paragraph renders as base-styled runs', () {
      final lines = renderMarkdown('just words', style);
      expect(lines, hasRuns([
        [plainRun('just words')],
      ]));
    });

    test('soft line breaks split a paragraph into visual lines', () {
      final lines = renderMarkdown('one\ntwo', style);
      expect(lines, hasRuns([
        [plainRun('one')],
        [plainRun('two')],
      ]));
    });

    test('fenced code block renders as bar lines, verbatim', () {
      final lines = renderMarkdown('```\nint x = 1;\n  keep  spacing\n```', style);
      expect(lines.length, 2);
      for (final line in lines) {
        expect(line.bar, style.codeBlock);
      }
      expect(lines[0].runs.single.text, 'int x = 1;');
      expect(lines[1].runs.single.text, '  keep  spacing');
    });

    test('blank lines inside a fence keep the bar (are content)', () {
      final lines = renderMarkdown('```\na\n\nb\n```', style);
      expect(lines.length, 3);
      expect(lines[1].bar, style.codeBlock);
      expect(lines[1].runs, isEmpty);
    });

    test('fence info string is dropped', () {
      final lines = renderMarkdown('```dart\nvoid f() {}\n```', style);
      expect(lines.single.runs.single.text, 'void f() {}');
    });

    test('bullet lists get markers and nesting indents', () {
      final lines = renderMarkdown('- a\n- b\n  - b1', style);
      expect(lines, hasRuns([
        [plainRun('• '), plainRun('a')],
        [plainRun('• '), plainRun('b')],
        [plainRun('  • '), plainRun('b1')],
      ]));
    });

    test('ordered lists number from 1 (or the start attribute)', () {
      final lines = renderMarkdown('1. a\n2. b', style);
      expect(lines, hasRuns([
        [plainRun('1. '), plainRun('a')],
        [plainRun('2. '), plainRun('b')],
      ]));
    });

    test('loose list items (p-wrapped) still render on marker lines', () {
      final lines = renderMarkdown('- a\n\n- b\n', style);
      final flat = lines.map((l) => l.runs.map((r) => r.text).join()).toList();
      expect(flat, anyElement(contains('• a')));
      expect(flat, anyElement(contains('• b')));
    });

    test('blockquote prefixes each line with a dim rail', () {
      final lines = renderMarkdown('> quoted\n> more', style);
      expect(lines, hasRuns([
        [styledRun('│ ', style.dim), plainRun('quoted')],
        [styledRun('│ ', style.dim), plainRun('more')],
      ]));
    });

    test('thematic break renders as a dim rule', () {
      final lines = renderMarkdown('a\n\n---\n\nb', style);
      final rule = lines.firstWhere(
          (l) => l.runs.isNotEmpty && l.runs.first.text == '───');
      expect(rule.runs.single.code, style.dim);
    });

    test('top-level blocks are blank-line separated', () {
      final lines = renderMarkdown('h\n\np', style);
      // h + blank + p — no trailing blank (the turn terminator adds it).
      expect(lines.length, 3);
      expect(lines[1].isBlank, isTrue);
      expect(lines.last.isBlank, isFalse);
    });
  });

  group('renderMarkdown — inlines', () {
    test('bold', () {
      final lines = renderMarkdown('a **b** c', style);
      expect(lines, hasRuns([
        [plainRun('a '), styledRun('b', '1'), plainRun(' c')],
      ]));
    });

    test('italic', () {
      final lines = renderMarkdown('a *b* c', style);
      expect(lines, hasRuns([
        [plainRun('a '), styledRun('b', '3'), plainRun(' c')],
      ]));
    });

    test('bold+italic composes to 1;3', () {
      final lines = renderMarkdown('***x***', style);
      expect(lines, hasRuns([
        [styledRun('x', '1;3')],
      ]));
    });

    test('nested emphasis keeps outer bits', () {
      final lines = renderMarkdown('**a *b* c**', style);
      expect(lines, hasRuns([
        [styledRun('a ', '1'), styledRun('b', '1;3'), styledRun(' c', '1')],
      ]));
    });

    test('underscore emphasis matches asterisk', () {
      final lines = renderMarkdown('__b__ _i_', style);
      expect(lines, hasRuns([
        [styledRun('b', '1'), plainRun(' '), styledRun('i', '3')],
      ]));
    });

    test('inline code drops backticks and takes the inlineCode pill', () {
      final lines = renderMarkdown('run `dart test` now', style);
      expect(lines, hasRuns([
        [plainRun('run '), styledRun('dart test', style.inlineCode), plainRun(' now')],
      ]));
    });

    test('link renders label styled with a dim url tail', () {
      final lines = renderMarkdown('see [docs](https://tina.dev) ok', style);
      expect(lines, hasRuns([
        [
          plainRun('see '),
          styledRun('docs', style.link),
          styledRun(' (https://tina.dev)', style.dim),
          plainRun(' ok'),
        ],
      ]));
    });

    test('autolink with empty gap between label and url renders once', () {
      final lines = renderMarkdown('<https://tina.dev>', style);
      expect(lines, hasRuns([
        [styledRun('https://tina.dev', style.link)],
      ]));
    });

    test('entities and escapes decode in rendered text', () {
      final lines = renderMarkdown('a &amp; b \\* not em &#65;&#x42;', style);
      expect(lines, hasRuns([
        [plainRun('a & b * not em AB')],
      ]));
    });

    test('code spans keep their source entities (one decode of the parser escape)', () {
      // The parser entity-encodes code content once for HTML output; the
      // renderer decodes exactly that layer, so the source round-trips.
      final lines = renderMarkdown('`a &amp; b`', style);
      expect(lines, hasRuns([
        [styledRun('a &amp; b', style.inlineCode)],
      ]));
    });

    test('code blocks keep their source entities', () {
      final lines = renderMarkdown('```\na &amp; b\n```', style);
      expect(lines.single.runs.single.text, 'a &amp; b');
    });

    test('emphasis inside a list item works', () {
      final lines = renderMarkdown('- **big** point', style);
      expect(lines, hasRuns([
        [plainRun('• '), styledRun('big', '1'), plainRun(' point')],
      ]));
    });

    test('raw html falls back to text content, nothing dropped', () {
      final lines = renderMarkdown('<div>kept</div>', style);
      final flat = lines.map((l) => l.runs.map((r) => r.text).join()).join();
      expect(flat, contains('kept'));
    });
  });

  group('serializeLine', () {
    test('styled mode embeds open/close SGR and restores the base', () {
      const line = MarkdownLine(runs: [
        MarkdownRun('a ', null),
        MarkdownRun('b', '1'),
        MarkdownRun(' c', null),
      ]);
      final out = serializeLine(line, style, styled: true).text;
      expect(out, 'a \x1b[1mb\x1b[0m\x1b[${style.base}m c');
    });

    test('plain mode emits text only', () {
      const line = MarkdownLine(runs: [
        MarkdownRun('a ', null),
        MarkdownRun('b', '1'),
      ]);
      final out = serializeLine(line, style, styled: false).text;
      expect(out, 'a b');
    });

    test('bar style is carried on the line, not into the text', () {
      const line = MarkdownLine(bar: '100', runs: [MarkdownRun('x', null)]);
      final out = serializeLine(line, style, styled: true);
      expect(out.bar, '100');
      expect(out.text, 'x');
    });
  });

  group('MarkdownStreamSplitter', () {
    test('holds a lone paragraph until flushed', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('hello\n'), isEmpty);
      expect(s.flush(), 'hello\n');
      expect(s.flush(), '');
    });

    test('blank line closes a block; blanks collapse', () {
      final s = MarkdownStreamSplitter();
      // Both blocks close: 'a' at the first blank, 'b' at the final one.
      expect(s.push('a\n\n\n\nb\n\n'), ['a\n', 'b\n']);
      expect(s.hasPending, isFalse);
      expect(s.flush(), '');
    });

    test('deltas splitting a newline boundary still close correctly', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('a\n'), isEmpty);
      // '\n' + '\n' = the blank line assembles across delta boundaries.
      expect(s.push('\n'), ['a\n']);
      expect(s.push('b'), isEmpty);
      expect(s.flush(), 'b');
    });

    test('fence holds interior blank lines and closes at the fence', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('```\na\n'), isEmpty);
      expect(s.push('\n'), isEmpty); // blank INSIDE the fence — no split
      expect(s.push('b\n```\n'), ['```\na\n\nb\n```\n']);
      expect(s.flush(), '');
    });

    test('paragraph before a fence flushes with the fence as one block', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('intro\n```\ncode\n```\nafter\n\n'),
          ['intro\n```\ncode\n```\n', 'after\n']);
      expect(s.flush(), '');
    });

    test('tilde fences work', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('~~~\nx\n~~~\n'), ['~~~\nx\n~~~\n']);
    });

    test('a mismatched closing fence is interior content', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('```\ncode\n~~~\nstill\n```\n'), ['```\ncode\n~~~\nstill\n```\n']);
    });

    test('unclosed fence flushes as the remainder', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('```\ncode\nmore\n'), isEmpty);
      expect(s.flush(), '```\ncode\nmore\n');
    });

    test('an unterminated final line never closes a block', () {
      final s = MarkdownStreamSplitter();
      expect(s.push('a\nb'), isEmpty); // 'b' has no newline yet
      expect(s.push('c\n\n'), ['a\nbc\n']);
    });
  });
}
