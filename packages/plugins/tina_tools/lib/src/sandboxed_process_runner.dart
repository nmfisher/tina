/// Process boundary: read-only denies execution; other modes require an
/// approval or a matching human session grant. The mode plugin routes reviews
/// to a human or the automatic safety judge; OS confinement remains separate.
library;

import 'dart:io' show Platform;
import 'dart:convert' show jsonEncode;

import 'glob.dart' show fileGlobMatch;
import 'permissions.dart';
import 'process_runner.dart';

/// The session mode a [SandboxedProcessRunner] enforces. Re-exported from
/// the permissions vocabulary so callers need one import less.
export 'permissions.dart' show PermissionMode;

/// One policy rule, named so a reason can cite it. These are the words the
/// model reads in a refusal; keep them specific.
enum CommandRule {
  /// Execution requires approval even within writable directories.
  permissionMode,

  /// `readOnly`: every command is refused outright — no classifier, no ask.
  readOnly,

  /// The command provably reads, or creates/edits/moves/deletes, nothing
  /// outside the session's writable directories, and shows no sign of
  /// needing to reach the network while network is off.
  insideWritableSet,

  /// A session grant (`CommandGrants`) remembered for this exact command
  /// covers it.
  sessionGrant,

  /// The command might create, edit or delete something outside the
  /// writable directories, or needs to reach the network while network is
  /// off — the approver decides.
  outsideSession,

  /// A single collapsed shell string (`/bin/sh -c <string>`, the bash-tool
  /// shape). What the string does cannot be proven from argv — it may read,
  /// write, or reach the network anywhere — so it never rides the writable
  /// directories; it asks, always.
  shellString,
}

/// Why the table landed where it did, in one plain phrase — the string a UI
/// shows and the model reads. Names the rule and, when it matters, the
/// first offending path.
String commandReason(CommandRule rule, ProcessRequest request) =>
    switch (rule) {
      CommandRule.permissionMode => 'allow command (${request.command})?',
      CommandRule.readOnly =>
        'denied: commands are not permitted in read-only mode '
            '(${request.command})',
      CommandRule.insideWritableSet =>
        'command stays inside the session\'s writable directories '
            '(${request.command})',
      CommandRule.sessionGrant =>
        'allowed by session grant (${request.command})',
      CommandRule.outsideSession =>
        'allow command outside the session\'s writable directories '
            '(${request.command})?',
      CommandRule.shellString =>
        'allow a shell command string? what it runs cannot be checked '
            'against the writable directories (${request.arguments.join(' ')})',
    };

/// Session-scoped "always" answers for commands, remembered as exact command
/// lines — the twin of `FileGrants`, but there is no sibling-glob trick here:
/// a command line has no directory to widen into, and widening `"git
/// status"` to `"git *"` would silently approve a tree of unrelated
/// commands. A host may remember a prefix glob deliberately (see
/// [CommandGrants.rememberPattern]).
///
/// Sessions are in-memory by design: grants die with the object, so nothing
/// outlives the run that approved it.
final class CommandGrants {
  final List<String> _patterns = [];
  final Set<String> _exactLines = {};
  final Map<String, String> _requests = {};

  static String _key(ProcessRequest request) => jsonEncode([
        request.command,
        request.arguments,
        request.workingDirectory,
        request.environment,
        request.stdin,
      ]);

  void rememberRequest(ProcessRequest request) {
    _requests[_key(request)] = lineOf(request);
  }

  bool coversRequest(ProcessRequest request) =>
      _requests.containsKey(_key(request)) ||
      patternFor(lineOf(request)) != null;

  /// Human-readable labels for explicit grants and approved requests.
  List<String> get patterns =>
      List.unmodifiable([..._exactLines, ..._patterns, ..._requests.values]);

  bool get isEmpty => patterns.isEmpty;
  int get length => patterns.length;

  /// The command line this request is remembered as: program joined with its
  /// arguments by single spaces. Used for display and explicit pattern grants;
  /// automatic approvals use the structured request identity.
  static String lineOf(ProcessRequest request) =>
      [request.command, ...request.arguments].join(' ');

  /// Remembers one exact command line. Returns false if it was already
  /// present (idempotent, mirroring `FileGrants.remember`).
  bool remember(String commandLine) {
    return _exactLines.add(commandLine);
  }

  /// Remembers a glob (a `fileGlobMatch` pattern, e.g. `'git status'` or the
  /// wider `'git *'`). A host's deliberate widening; the runner itself only
  /// ever calls [rememberRequest].
  bool rememberPattern(String glob) {
    if (_patterns.contains(glob)) return false;
    _patterns.add(glob);
    return true;
  }

  /// The first pattern that matches [commandLine], or null.
  String? patternFor(String commandLine) {
    if (_exactLines.contains(commandLine)) return commandLine;
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

  /// The session's writable directories — paths a command may create or
  /// modify. A command that stays inside them (and needs no network) runs
  /// without asking; anything else asks.
  final WritableDirectories writableDirectories;

  /// Whether the session lets commands reach the network. Off by default:
  /// a command that appears to need network asks.
  final bool networkOff;

  /// The approver — the same object the filesystem takes. Nothing wired means
  /// deny: fail closed.
  Approver? approver;

  Future<Approval> Function(ProcessRequest, String)? commandApprover;

  /// Session grants remembered from "always" answers.
  final CommandGrants grants;

  SandboxedProcessRunner({
    required this.inner,
    this.mode = PermissionMode.ask,
    WritableDirectories? writableDirectories,
    this.networkOff = true,
    this.approver,
    this.commandApprover,
    CommandGrants? grants,
  })  : writableDirectories = writableDirectories ?? WritableDirectories(),
        grants = grants ?? CommandGrants();

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    final decision = decideCommand(request, mode,
        writableDirectories: writableDirectories,
        networkOff: networkOff,
        grants: grants);
    switch (decision.verdict) {
      case ToolVerdict.allow:
        return _completed(
            await inner.run(request, control: control), decision.reason);
      case ToolVerdict.deny:
        return CommandRefused(decision.reason);
      case ToolVerdict.ask:
        final approver = this.approver;
        if (approver == null && commandApprover == null) {
          return CommandRefused('${decision.reason} — denied: no approver is '
              'wired to approve it');
        }
        switch (await (commandApprover?.call(request, decision.reason) ??
            approver!(_asFileOperation(request), decision.reason))) {
          case Approval.yes:
            return _completed(
                await inner.run(request, control: control), decision.reason);
          case Approval.always:
            grants.rememberRequest(request);
            return _completed(
                await inner.run(request, control: control), decision.reason);
          case Approval.no:
            return CommandRefused('${decision.reason} — denied by the user');
        }
    }
  }

  /// The inner runner may refuse (a host-enforced seam) or report an
  /// OS-sandbox denial ([CommandBlocked]); neither may be masked as an
  /// ordinary completed run. A completed run gains the decision's note.
  static RunOutcome _completed(RunOutcome inner, String note) =>
      switch (inner) {
        CommandCompleted(
          :final exitCode,
          :final stdout,
          :final stderr,
          :final cancelled,
          :final timedOut
        ) =>
          CommandCompleted(
              exitCode: exitCode,
              stdout: stdout,
              stderr: stderr,
              note: inner.note ?? note,
              cancelled: cancelled,
              timedOut: timedOut),
        CommandRefused() => inner,
        CommandBlocked() => inner,
        CommandRunning() => inner,
      };

  /// The approver is the filesystem's type: a [FileOperation]. The command's
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
/// remembered by a [CommandGrants] pattern runs outside read-only without asking
/// again.
CommandDecision decideCommand(
  ProcessRequest request,
  PermissionMode mode, {
  required WritableDirectories writableDirectories,
  required bool networkOff,
  CommandGrants? grants,
}) {
  if (mode == PermissionMode.readOnly) {
    // No classifier, no "statically read-only command" route: every command
    // is refused, and nobody is asked.
    return (
      verdict: ToolVerdict.deny,
      reason: commandReason(CommandRule.readOnly, request)
    );
  }
  if (grants?.coversRequest(request) == true) {
    return (
      verdict: ToolVerdict.allow,
      reason: commandReason(CommandRule.sessionGrant, request),
    );
  }
  // A single unbreakable string (`sh -c <string>`, the bash-tool shape) can
  // redirect, read, or reach the network without anything in argv saying so,
  // so it is never certified by the writable directories — it asks, the way every
  // unprovable command does. Literal argv keeps the quiet path.
  if (argumentsCollapsed(request)) {
    return (
      verdict: ToolVerdict.ask,
      reason: commandReason(CommandRule.shellString, request),
    );
  }
  if (writableDirectories.covers(request) &&
      !(networkOff && needsNetwork(request))) {
    return (
      verdict: ToolVerdict.ask,
      reason: commandReason(CommandRule.permissionMode, request)
    );
  }
  return (
    verdict: ToolVerdict.ask,
    reason: commandReason(CommandRule.outsideSession, request),
  );
}

/// The verdict plus the reason — same shape as `FileDecision`.
typedef CommandDecision = ({ToolVerdict verdict, String reason});

/// True when a request collapses a shell command into one argv element —
/// the `command: <shell>, arguments: ['-c', <string>]` shape every bash tool
/// produces. What the string runs cannot be proven from argv: redirects,
/// backticks, and newlines mean the writable directories can say nothing about it.
/// Such requests never ride the writable directories; they ask (or refuse in
/// read-only mode).
///
/// Shape test: the basename of [ProcessRequest.command] is a known shell and
/// the shell's flag is followed by a payload — i.e. there is at least one
/// argument that is not the flag itself. Flags carrying the string as their
/// value (`-c` on BSD, `-c` on Windows) are matched by name, not position,
/// so any arguments list containing `-c` with something after it counts.
bool argumentsCollapsed(ProcessRequest request) {
  final shell = request.command.split(Platform.pathSeparator).last;
  if (!_shells.contains(shell)) return false;
  // `-c <string>`: the payload argument exists whenever the args list holds
  // anything besides the flag tokens themselves.
  return request.arguments.any((a) => a != '-c' && a != '--command');
}

const _shells = {'sh', 'bash', 'dash', 'ash', 'zsh', 'ksh', 'bash5'};

/// The session's writable directories, and the one heuristic that keeps the table
/// honest: which requests provably stay inside them.
///
/// **Provably is the operative word.** A command string cannot be classified,
/// so for `bash` there is no proof, and unprovable means ask (or refuse in
/// `readOnly`). Only argv-shaped requests — what `exec` builds — can be
/// judged: their absolute file arguments are checked against the
/// directories, their cwd must sit inside them, and anything path-shaped
/// but unresolved asks.
///
/// This is a gate on arguments, not a boundary on behaviour. There is no
/// OS-level sandbox behind it — no `bwrap`, no `sandbox-exec` — so a
/// command that passes may still write anywhere once it starts.
final class WritableDirectories {
  final List<String> _roots;

  WritableDirectories([List<String>? roots])
      : _roots = List.of(roots ?? const []);

  /// The roots, oldest first. Unmodifiable view.
  List<String> get roots => List.unmodifiable(_roots);

  /// Adds a writable root (a directory path). The project root is added by
  /// the tool wiring; a host may add more (`/tmp/build`).
  void add(String root) {
    if (!_roots.contains(root)) _roots.add(root);
  }

  bool contains(String path) => _roots.any((r) => _isUnder(path, r));

  /// Whether this grant covers [request]: checks the working directory, and
  /// the arguments that are path-shaped — where path-shaped means starting
  /// with `/`, `./` or `../`, or being exactly `.` or `..`. A bare relative
  /// token like `etc/passwd` and an option-embedded path like
  /// `--out=../../x` are not path-shaped and therefore not judged. It says
  /// nothing about what the program does once it runs.
  bool covers(ProcessRequest request) {
    final cwd = request.workingDirectory;
    if (cwd != null && !contains(cwd)) return false;
    // No cwd and no path-shaped argument: nothing here names a place outside
    // the directories. The command itself is still unclassified — this only
    // means the *arguments* give no reason to ask.
    for (final a in request.arguments) {
      if (!_argumentInsideRoots(a)) return false;
    }
    return true;
  }

  /// One argument is inside the writable directories when it is not
  /// path-shaped, or is path-shaped and resolves inside. Absolute paths are
  /// judged directly; relative paths are judged against the cwd (already
  /// checked).
  bool _argumentInsideRoots(String argument) {
    if (!_isPathShaped(argument)) return true;
    if (argument.startsWith('/')) return contains(argument);
    // Relative and path-shaped: relative to the (already-checked) cwd, so
    // it cannot escape without the cwd check failing first. Keep it simple
    // and refuse to certify anything starting with `..` — that asks.
    return !argument.startsWith('..');
  }

  /// Cheap shape test — not a claim that the file exists. A token counts as
  /// path-shaped when it starts with `/`, `./` or `../`, or is exactly `.`
  /// or `..`. A bare relative token like `etc/passwd` is not path-shaped,
  /// and neither is an option-embedded path like `--out=../../x` — those
  /// are not judged here.
  static bool _isPathShaped(String token) =>
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
  'curl',
  'wget',
  'ssh',
  'scp',
  'rsync',
  'ping',
  'nc',
  'netcat',
  'ftp',
  'dig',
  'nslookup',
  'host',
  'telnet',
};

/// True when [child] is [parent] or lies under it — same discipline as the
/// filesystem's helper, so `/tmp/x` is not "under" `/tmp/xy`.
bool _isUnder(String child, String parent) {
  String trail(String path) => path.endsWith('/') ? path : '$path/';
  final c = trail(child == '' ? '/' : child);
  final par = trail(parent == '' ? '/' : parent);
  return c == par || c.startsWith(par);
}
