/// Pluggable completion interface and subsequence-fuzzy ranking helpers.
///
/// Pure Dart, with no terminal or engine dependencies — this is the neutral
/// seam shared by the TUI toolkit's [CompletionProvider] consumers (the picker
/// and line editor in `tina_console`) and application-level providers such as
/// `GitFileCompletionProvider`. Keeping it in a dependency-free leaf package
/// lets both the terminal frontend and any alternate (web/headless) frontend
/// implement and consume the same type without one depending on the other.
///
/// - [CompletionProvider]: source of completion suggestions for an interactive
///   picker/editor.
/// - [fuzzyScore] / [rankFuzzy]: subsequence-fuzzy ranking helpers.
library;

export 'src/fuzzy.dart';
export 'src/provider.dart';
