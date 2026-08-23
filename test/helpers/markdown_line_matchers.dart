import 'package:test/test.dart';

import 'package:tina/tui/markdown_renderer.dart';

/// Matchers for [MarkdownLine] / [MarkdownRun] that compare structurally
/// (text + style code), so renderer tests read as the shapes they assert.

/// Matches a [MarkdownRun] with exactly [text] and no inline style.
Matcher plainRun(String text) => styledRun(text, null);

/// Matches a [MarkdownRun] with exactly [text] and the given inline SGR
/// [code] (null = base style).
Matcher styledRun(String text, String? code) =>
    _RunMatcher(text, code);

/// Matches a list of [MarkdownLine]s against the expected per-line run
/// shapes. Blank lines must be listed explicitly as an empty run list.
Matcher hasRuns(List<List<Matcher>> expected) =>
    _LinesMatcher(expected);

class _RunMatcher extends Matcher {
  final String text;
  final String? code;

  const _RunMatcher(this.text, this.code);

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! MarkdownRun) return false;
    return item.text == text && item.code == code;
  }

  @override
  Description describe(Description desc) =>
      desc.add('run($text @ ${code ?? 'base'})');
}

class _LinesMatcher extends Matcher {
  final List<List<Matcher>> expected;

  const _LinesMatcher(this.expected);

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! List<MarkdownLine>) return false;
    final actual = item;
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      final expLine = expected[i];
      final actLine = actual[i].runs;
      if (actLine.length != expLine.length) return false;
      for (var j = 0; j < actLine.length; j++) {
        if (!expLine[j].matches(actLine[j], matchState)) return false;
      }
      // Bar style must be null for plain lines (hasRuns asserts prose
      // shapes; bar lines assert .bar directly in the tests).
      if (actual[i].bar != null && expected[i].isNotEmpty) return false;
    }
    return true;
  }

  @override
  Description describe(Description desc) {
    desc = desc.add('lines with runs [');
    for (final line in expected) {
      desc = desc.add('${line.map((m) => m.describe(StringDescription())).join(', ')}; ');
    }
    return desc.add(']');
  }
}
