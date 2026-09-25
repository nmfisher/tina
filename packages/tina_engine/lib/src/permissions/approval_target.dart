/// What one tool call is asking to be allowed to do.
///
/// One place decides this for every tool, so the three things that used to be
/// free to drift apart — what the approval prompt shows, what an "always" answer
/// remembers, and what a `--allow` / `--deny` rule matches against — are all
/// read off the same value.
///
/// [label] is what the user sees, and it is also the string a configured rule is
/// matched against. [remember] is the rule an "always" answer installs, as a glob
/// over [label].
final class ApprovalTarget {
  /// What the prompt shows: the command, file path, url, workflow or query.
  ///
  /// Also the string rules match, so a rule that names something the user was
  /// never shown cannot exist.
  final String label;

  /// The rule an "always" answer installs, as a glob over [label].
  final String remember;

  /// Whether `*` in a rule spans `/`.
  ///
  /// True for commands and urls: their labels are full of slashes, so `*`
  /// stopping at one would make `curl *` or `https://host/*` match almost
  /// nothing. False for paths, where `*` stopping at a segment is the familiar
  /// shell behaviour and `**` is what crosses directories.
  final bool starMatchesSlash;

  /// True when [label] is a serialized invocation (see [ApprovalTarget.invocation]).
  ///
  /// A rule whose pattern is itself one of those is compared exactly rather than
  /// globbed, because `[` and `]` are glob metacharacters.
  final bool invocation;

  const ApprovalTarget({
    required this.label,
    required this.remember,
    this.starMatchesSlash = false,
    this.invocation = false,
  });

  /// A command, query, region or other exact argument: "always" means this exact
  /// text.
  ///
  /// An empty [text] keeps the fail-closed shape — nothing to show, and a rule
  /// that can only match the tool as a whole.
  factory ApprovalTarget.exact(String text) => ApprovalTarget(
        label: text,
        remember: text.isEmpty ? '*' : text,
        starMatchesSlash: true,
      );

  /// A serialized invocation: what runs, where, and with which environment.
  ///
  /// "always" means exactly this invocation — a different environment is a
  /// different authorization.
  factory ApprovalTarget.invocation(String json) => ApprovalTarget(
        label: json,
        remember: json,
        starMatchesSlash: true,
        invocation: true,
      );

  /// A file: "always" covers the file's directory, so one approval covers a
  /// directory of edits.
  ///
  /// A path with no directory component (`/foo.txt`) is remembered exactly: a
  /// directory rule for it would be the wildcard, which for a file tool compiles
  /// to `[^/]*` and so could never match the absolute path it came from.
  factory ApprovalTarget.path(String filePath) {
    if (filePath.isEmpty) return unknown;
    final lastSlash = filePath.lastIndexOf('/');
    if (lastSlash <= 0) {
      return ApprovalTarget(label: filePath, remember: filePath);
    }
    return ApprovalTarget(
      label: filePath,
      remember: '${filePath.substring(0, lastSlash)}/*',
    );
  }

  /// A url: "always" means this exact url. Rules may glob the whole thing,
  /// slashes included.
  factory ApprovalTarget.url(String url) => ApprovalTarget(
        label: url,
        remember: url.isEmpty ? '*' : url,
        starMatchesSlash: true,
      );

  /// Nothing identifiable in the input — the fail-closed default.
  ///
  /// A rule on it can only match the tool as a whole, which is exactly why the
  /// registry sweep requires a tool to produce a real target before it is
  /// allowed to prompt.
  static const ApprovalTarget unknown =
      ApprovalTarget(label: '', remember: '*');
}
