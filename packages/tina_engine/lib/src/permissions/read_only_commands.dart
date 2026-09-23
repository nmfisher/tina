/// Static fast path for read-all's classifier-gated shell: is this bash input
/// *provably* read-only by inspection — no redirection, no substitution, and
/// every command segment one of a fixed set of readers?
///
/// The design rule: a miss must be a DENY-direction miss. Anything this
/// analyzer does not fully understand — an unknown program, a redirect
/// operator, `$`, a backslash, a quote before the command name — fails the
/// check, and the call surfaces to the permission classifier instead. A
/// false negative here costs one judged round-trip (remembered per exact
/// command, so repeats are free); a false positive here would execute code
/// in a mode that promised none.
///
/// Deliberately excluded even though they are often harmless — `sed`, `awk`,
/// `tar`, `git`, `env`, `xargs`, `timeout`, `nice`, `sudo`, interpreters,
/// interactive viewers — each can write a file, execute a program, or hide
/// an effect behind flags this checker does not model. The classifier is the
/// escape hatch for everything excluded here; `git` in particular should use
/// its own fenced read-only tool rather than a shell.

/// Whether this bash tool input qualifies for the static read-only path.
///
/// A custom `environment` is part of what the model is asking for — a PATH
/// override could make an allowlisted name resolve to a different binary —
/// so only the default environment is statically provable. (The classifier
/// sees the whole input, environment included, for everything else.)
bool isReadOnlyShellInput(Map<String, dynamic> input) {
  if (input['environment'] != null) return false;
  final command = input['command'];
  return command is String && isReadOnlyShellCommand(command);
}

/// Whether [command] — run by the bash tool as `/bin/sh -c '<command>'` —
/// consists only of segments this policy can prove read-only.
bool isReadOnlyShellCommand(String command) {
  // Substitution (`$`, backtick) and redirection (`>`, `<`, and their
  // `>>`/`<<<`/`>&` forms) anywhere disqualify the whole command: they are
  // the two mechanisms that turn an allowlisted reader into a writer or a
  // program launcher. `$` also bans plain `$VAR` expansion — word expansion
  // cannot itself execute, but an expanded word can become an option (say,
  // `grep --pre=…`), and the analyzer cannot see through it.
  if (command.contains(RegExp(r'[$`<>]'))) return false;
  // Split on the operators that separate commands; every resulting segment
  // must independently pass. An escape may split a segment mid-word (for
  // example `cat a\; rm b`), but that errs toward a non-allowlisted head —
  // never toward running something unchecked.
  for (final segment in command.split(RegExp(r'[;|&\n\r]+'))) {
    if (!_segmentIsReadOnly(segment)) return false;
  }
  return true;
}

/// Readers with no write-capable flag this checker needs to model. Exact
/// membership doubles as the safety check on the command name: the set holds
/// only bare lowercase names, so a slash (`/bin/cat`), a glob (`c*`), a
/// quote (`'cat'`), or a brace expansion (`{cat,touch}`) as the first word
/// can never match — the program must be a bare name resolved through PATH,
/// exactly one of these.
const Set<String> _readers = {
  // Core readers.
  'cat', 'head', 'tail', 'nl', 'tac', 'wc', 'ls', 'dir', 'stat', 'file',
  'du', 'df', 'pwd', 'printenv', 'which', 'id', 'whoami', 'groups', 'date',
  'uname', 'tree', 'basename', 'dirname', 'realpath', 'readlink', 'seq',
  'rev', 'cut', 'tr', 'sort', 'uniq', 'comm', 'diff', 'cmp', 'join',
  'column', 'fmt', 'fold',
  // Search.
  'grep', 'egrep', 'fgrep', 'rg', 'find',
  // Bytes, hashes, structured queries (stdout only without redirection).
  'od', 'hexdump', 'xxd', 'base64', 'md5sum', 'shasum', 'sha1sum',
  'sha256sum', 'sha512sum', 'cksum', 'jq',
  // Shell builtins/keywords that only compute or print.
  'echo', 'printf', 'test', '[', 'true', 'false', 'expr',
};

/// Flag prefixes that make an otherwise-allowlisted reader write (or launch
/// something): matched against quote-stripped, escape-stripped words after
/// the command name, at any position — position-insensitivity can only deny
/// more, never less.
const Map<String, List<String>> _deniedFlags = {
  // -delete; -exec/-execdir, -ok/-okdir (prefix covers the -dir variants);
  // -fprint/-fprintf/-fprint0, -fls write their listings to files.
  'find': ['-delete', '-exec', '-ok', '-fprint', '-fls'],
  // The output-file options (not df-style column selection: the table is
  // per command, so only sort/uniq's `-o` means a file here).
  'sort': ['-o', '--output'],
  'uniq': ['-o', '--output'],
  // GNU grep and ripgrep execute this before scanning a directory tree.
  'grep': ['--pre'],
  'egrep': ['--pre'],
  'fgrep': ['--pre'],
  'rg': ['--pre'],
  // `date -s` sets the system clock; `file -C` compiles magic to a file.
  'date': ['-s', '--set'],
  'file': ['-C', '--compile'],
};

bool _segmentIsReadOnly(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return true; // nothing runs
  final head = trimmed.split(RegExp(r'\s+')).first;
  if (!_readers.contains(head)) return false;
  final denied = _deniedFlags[head];
  if (denied == null) return true;
  // Analyze flag-looking words with quotes and backslash escapes removed:
  // sh does the same unquoting before argv reaches the program, so `'-i'`
  // and `\-i` must be seen as `-i` here too. Analysis only — the command
  // itself is passed through untouched.
  final words = _noiseless(trimmed).trim().split(RegExp(r'\s+'));
  for (final word in words.skip(1)) {
    for (final flag in denied) {
      if (word.startsWith(flag)) return false;
    }
  }
  return true;
}

/// Strip quote characters and backslash escapes, the way a shell would while
/// tokenizing — used only for flag detection, where a hidden `-i` must not
/// hide.
String _noiseless(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      b.write(s[i + 1]);
      i++;
    } else if (c != "'" && c != '"') {
      b.write(c);
    }
  }
  return b.toString();
}
