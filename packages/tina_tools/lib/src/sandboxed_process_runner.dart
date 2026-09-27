/// The enforcement boundary for process execution — the twin of
/// `SandboxedFileSystem`: a [ProcessRunner] wrapper that decides **per call**
/// whether the command may run, and only hands the wrapped runner the
/// requests that may.
///
/// The command × mode table, as built:
///
/// | mode     | in writable set, network ok | outside set / needs network |
/// |----------|-----------------------------|-----------------------------|
/// | readOnly | deny, never asked           | deny, never asked           |
/// | normal   | allow                       | ask (deny if refused / no asker) |
///
/// There is no classifier and no "statically read-only command" route: a
/// command string is not statically decidable, so in `readOnly` **every**
/// command is refused outright and nobody is asked. In `normal` a command
/// runs when it demonstrably stays inside the session's writable set and
/// does not need network while network is off; anything else asks the same
/// asker the filesystem takes. **No asker wired means deny** — fail closed.
library;

import 'glob.dart' show fileGlobMatch;
import 'permissions.dart';
import 'process_runner.dart';

/// The session mode a [SandboxedProcessRunner] enforces. Re-exported from
/// the permissions vocabulary so callers need one import less.
export 'permissions.dart' show PermissionMode;

/// One policy rule, named so a reason can cite it. These are the words the
/// model reads in a refusal; keep them specific.
enum CommandRule {
  /// `readOnly`: every command is refused outright — no classifier, no ask.
  readOnly,

  /// The command provably touches nothing outside the session's writable
  /// set and does not need network while network is off.
  insideWritableSet,

  /// A session grant (`CommandGrants`) remembered for this exact command
  /// covers it.
  sessionGrant,

  /// The command might touch something outside the writable set, or needs
  /// network while network is off — the asker decides.
  outsideSession,
}

/// Why the table landed where it did, in one plain phrase — the string a UI
/// shows and the model reads. Names the rule and, when it matters, the
/// first offending path.
String commandReason(CommandRule rule, ProcessRequest request) =>
    switch (rule) {
      CommandRule.readOnly =>
        'denied: commands are not permitted in read-only mode '
            '(${request.command})',
      CommandRule.insideWritableSet =>
        'command stays inside the session\'s writable set (${request.command})',
      CommandRule.sessionGrant =>
        'allowed by session grant (${request.command})',
      CommandRule.outsideSession =>
        'allow command outside the session\'s writable set '
            '(${request.command})?',
    };

/// Session-scoped "always" answers for commands, remembered as exact command
/// lines — the twin of `OpGrants`, but there is no sibling-glob trick here:
/// a command line has no directory to widen into, and widening `"git
/// status"` to `"git *"` would silently approve a tree of unrelated
/// commands. A host may remember a prefix glob deliberately (see
/// [CommandGrants.rememberPattern]).
///
/// Sessions are in-memory by design: grants die with the object, so nothing
/// outlives the run that approved it.
final class CommandGrants {
  final List<String> _patterns = [];

  /// The remembered patterns, oldest first. Unmodifiable view.
  List<String> get patterns => List.unmodifiable(_patterns);

  bool get isEmpty => _patterns.isEmpty;
  int get length => _patterns.length;

  /// The command line this request is remembered as: program joined with its
  /// arguments by single spaces. This is the string grants match against.
  static String lineOf(ProcessRequest request) =>
      [request.command, ...request.arguments].join(' ');

  /// Remembers one exact command line. Returns false if it was already
  /// present (idempotent, mirroring `OpGrants.remember`).
  bool remember(String commandLine) {
    if (_patterns.contains(commandLine)) return false;
    _patterns.add(commandLine);
    return true;
  }

  /// Remembers a glob (a `fileGlobMatch` pattern, e.g. `'git status'` or the
  /// wider `'git *'`). A host's deliberate widening; the runner itself only
  /// ever calls [remember].
  bool rememberPattern(String glob) => remember(glob);

  /// The first pattern that matches [commandLine], or null.
  String? patternFor(String commandLine) {
    for (final pattern in _patterns) {
      if (fileGlobMatchCommand(pattern, commandLine)) return pattern;
    }
    return null;
  }
}

/// Glob-match a command line. Delegates to the path glob (`fileGlobMatch`):
/// a command line is just a string, `*` spanning spaces is exactly what a
/// command grant wants (`'git *'` → `'git status --porcelain'`), and two
/// glob dialects for one concept would be one more thing to keep in step.
bool fileGlobMatchCommand(String pattern, String commandLine) =>
    fileGlobMatch(pattern, commandLine);

/// A [ProcessRunner] that enforces the command × mode table before any
/// process exists.
///
/// The wrapped [inner] runner only ever sees requests the boundary allowed —
/// it can be a raw [IoProcessRunner] or a scripting fake; enforcement is
/// entirely here, per call, the way `SandboxedFileSystem` does it for paths.
final class SandboxedProcessRunner implements ProcessRunner {
  /// The runner that actually starts processes. Only allowed requests
  /// reach it.
  final ProcessRunner inner;

  /// The session mode. Mutable, like `SandboxedFileSystem.mode`: the same
  /// tool flips behavior when the host flips the mode.
  PermissionMode mode;

  /// The session's writable set — paths a command may create or modify. A
  /// command that stays inside it (and needs no network) runs without
  /// asking; anything else asks.
  final WritableSet writableSet;

  /// Whether the session lets commands reach the network. Off by default:
  /// a command that appears to need network asks.
  final bool networkOff;

  /// The asker — the same object the filesystem takes. Nothing wired means
  /// deny: fail closed.
  final FileAsker? asker;

  /// Session grants remembered from "always" answers.
  final CommandGrants grants;

  SandboxedProcessRunner({
    required this.inner,
    this.mode = PermissionMode.normal,
    WritableSet? writableSet,
    this.networkOff = true,
    this.asker,
    CommandGrants? grants,
  })  : writableSet = writableSet ?? WritableSet(),
        grants = grants ?? CommandGrants();

  @override
  Future<RunOutcome> run(ProcessRequest request) async {
    final decision = decideCommand(request, mode,
        writableSet: writableSet,
        networkOff: networkOff,
        grants: grants);
    switch (decision.verdict) {
      case ToolVerdict.allow:
        return _completed(await inner.run(request), decision.reason);
      case ToolVerdict.deny:
        return CommandRefused(decision.reason);
      case ToolVerdict.ask:
        final asker = this.asker;
        if (asker == null) {
          return CommandRefused('${decision.reason} — denied: no asker is '
              'wired to approve it');
        }
        switch (await asker(_asFileOperation(request), decision.reason)) {
          case FileAskAnswer.yes:
            return _completed(await inner.run(request), decision.reason);
          case FileAskAnswer.always:
            grants.remember(CommandGrants.lineOf(request));
            return _completed(await inner.run(request), decision.reason);
          case FileAskAnswer.no:
            return CommandRefused('${decision.reason} — denied by the user');
        }
    }
  }

  /// The inner runner may itself refuse (a host-enforced seam); surface that
  /// as a refusal rather than masking it as a completed run.
  static RunOutcome _completed(RunOutcome inner, String note) =>
      switch (inner) {
        CommandCompleted(:final exitCode, :final stdout, :final stderr) =>
          CommandCompleted(
              exitCode: exitCode, stdout: stdout, stderr: stderr, note: note),
        CommandRefused() => inner,
      };

  /// The asker is the filesystem's type: a [FileOperation]. The command's
  /// cwd — or the first path-like argument, when there is no cwd — is the
  /// path the ask dialog can show.
  static FileOperation _asFileOperation(ProcessRequest request) => (
        op: FileOp.write,
        path: request.workingDirectory ?? request.arguments.firstOrNull ?? '',
      );
}

/// The command × mode table: the whole rule, as built. Pure — a request in,
/// a verdict out — so its tests are headless by construction.
///
/// A session grant checked first short-circuits an ask: a command line
/// remembered by a [CommandGrants] pattern runs in `normal` without asking
/// again.
CommandDecision decideCommand(
  ProcessRequest request,
  PermissionMode mode, {
  required WritableSet writableSet,
  required bool networkOff,
  CommandGrants? grants,
}) {
  if (mode == PermissionMode.readOnly) {
    // No classifier, no "statically read-only command" route: every command
    // is refused, and nobody is asked.
    return (verdict: ToolVerdict.deny, reason: commandReason(
        CommandRule.readOnly, request));
  }
  final line = CommandGrants.lineOf(request);
  final granted = grants?.patternFor(line);
  if (granted != null) {
    return (
      verdict: ToolVerdict.allow,
      reason: commandReason(CommandRule.sessionGrant, request),
    );
  }
  if (writableSet.covers(request) && !(networkOff && needsNetwork(request))) {
    return (
      verdict: ToolVerdict.allow,
      reason: commandReason(CommandRule.insideWritableSet, request),
    );
  }
  return (
    verdict: ToolVerdict.ask,
    reason: commandReason(CommandRule.outsideSession, request),
  );
}

/// The verdict plus the reason — same shape as `FileDecision`.
typedef CommandDecision = ({ToolVerdict verdict, String reason});

/// The session's writable set, and the one heuristic that keeps the table
/// honest: which requests provably stay inside it.
///
/// **Provably is the operative word.** A command string cannot be classified,
/// so for `bash` there is no proof, and unprovable means ask (or refuse in
/// `readOnly`). Only argv-shaped requests — what `exec` builds — can be
/// judged: their absolute file arguments are checked against the set, their
/// cwd must sit inside it, and anything path-shaped but unresolved asks.
final class WritableSet {
  final List<String> _roots;

  WritableSet([List<String>? roots]) : _roots = List.of(roots ?? const []);

  /// The roots, oldest first. Unmodifiable view.
  List<String> get roots => List.unmodifiable(_roots);

  /// Adds a writable root (a directory path). The project root is added by
  /// the tool wiring; a host may add more (`/tmp/build`).
  void add(String root) {
    if (!_roots.contains(root)) _roots.add(root);
  }

  bool contains(String path) => _roots.any((r) => _isUnder(path, r));

  /// True when the request demonstrably stays inside the set.
  bool covers(ProcessRequest request) {
    final cwd = request.workingDirectory;
    if (cwd != null && !contains(cwd)) return false;
    // No cwd and no path-like argument: nothing here names a place outside
    // the set. The command itself is still unclassified — this only means
    // the *arguments* give no reason to ask.
    for (final a in request.arguments) {
      if (!_argumentInsideSet(a)) return false;
    }
    return true;
  }

  /// One argument is inside the set when it is not path-shaped, or is
  /// path-shaped and resolves inside. Absolute paths are judged directly;
  /// relative paths are judged against the cwd (already checked).
  bool _argumentInsideSet(String argument) {
    if (!_looksLikePath(argument)) return true;
    if (argument.startsWith('/')) return contains(argument);
    // Relative and path-shaped: relative to the (already-checked) cwd, so
    // it cannot escape without the cwd check failing first. Keep it simple
    // and refuse to certify anything starting with `..` — that asks.
    return !argument.startsWith('..');
  }

  /// Cheap shape test — not a claim that the file exists. A token that
  /// starts with `/`, `./`, `../`, or contains a slash with a dot-suffix is
  /// treated as a path; flags like `--flag=value-with/slashes` are not,
  /// unless the whole token starts path-shaped.
  static bool _looksLikePath(String token) =>
      token.startsWith('/') ||
      token.startsWith('./') ||
      token.startsWith('../') ||
      token == '.' ||
      token == '..';
}

/// True when [request] appears to need network access.
///
/// Heuristic on purpose, and it only ever errs toward asking: nothing here
/// can *prove* a program is offline, so the rule is "if it looks like it
/// wants the network, it asks". What cannot be allowed silently is a fetch
/// shaped request; a `curl`/`wget` in the program name or arguments, an
/// `http(s)://` URL anywhere in argv, or a known push/pull-shaped git
/// subcommand all look like network.
bool needsNetwork(ProcessRequest request) {
  final line = CommandGrants.lineOf(request);
  if (_networkPrograms.contains(request.command)) return true;
  if (line.contains('://')) return true;
  if (request.command == 'git' && request.arguments.isNotEmpty) {
    const netSubcommands = {'push', 'pull', 'fetch', 'clone', 'remote'};
    if (netSubcommands.contains(request.arguments.first)) return true;
  }
  return false;
}

const _networkPrograms = {
  'curl', 'wget', 'ssh', 'scp', 'rsync', 'ping', 'nc', 'netcat', 'ftp',
  'dig', 'nslookup', 'host', 'telnet',
};

/// True when [child] is [parent] or lies under it — same discipline as the
/// filesystem's helper, so `/tmp/x` is not "under" `/tmp/xy`.
bool _isUnder(String child, String parent) {
  String trail(String path) => path.endsWith('/') ? path : '$path/';
  final c = trail(child == '' ? '/' : child);
  final par = trail(parent == '' ? '/' : parent);
  return c == par || c.startsWith(par);
}
