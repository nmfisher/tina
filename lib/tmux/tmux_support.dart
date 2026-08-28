import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

/// The thin tmux integration (tin-f5xt). Tina uses tmux as its attach/detach
/// substrate rather than a built-in daemon: when `$TMUX` is set, a running
/// session can be detached (the agent keeps running in the tmux server) and
/// reattached with full scrollback via `tmux attach`. Nothing here changes for
/// users who don't run under tmux.
///
/// The string/decision logic is pure so it's unit-testable in isolation; the
/// one side effect ([detach], which spawns `tmux detach-client`) and the
/// once-per-install marker (the [markerPath] file) are isolated behind
/// [ProcessRunner] and an overridable [tinaDir] so tests can observe both
/// without a real tmux server or a real `~/.tina`.
class TmuxSupport {
  /// The process environment to read `$TMUX` from. Taken as a map (not the
  /// live [Platform]) so tests supply a deterministic `TMUX` without mutating
  /// the process environment.
  final Map<String, String> env;

  /// The seam for spawning `tmux`. Tests inject a scripted [ProcessRunner];
  /// production defaults to the real [IoProcessRunner].
  final ProcessRunner processRunner;

  /// The tina user-data dir the once-per-install notice marker lives under
  /// (`~/.tina`). Overridable so tests can point it at a temp dir.
  final Directory tinaDir;

  TmuxSupport({
    required this.env,
    ProcessRunner? processRunner,
    Directory? tinaDir,
  })  : processRunner = processRunner ?? const IoProcessRunner(),
        tinaDir = tinaDir ??
            Directory(p.join(env['HOME'] ?? env['USERPROFILE'] ?? '.', '.tina'));

  /// Whether we're running inside a tmux server — the `$TMUX` socket path is
  /// set by tmux for every client it spawns.
  bool get inTmux => (env['TMUX'] ?? '').isNotEmpty;

  /// The `tmux attach -t <session>` target: the server name is the last
  /// component of the `$TMUX` socket path (`/tmp/tmux-1000/default,12345,0`
  /// → `default`). Empty when not in tmux or the path has no name.
  String get attachTarget {
    final socket = env['TMUX'] ?? '';
    if (socket.isEmpty) return '';
    final base = p.basename(socket);
    final name = base.split(',').first;
    return name.isEmpty ? '' : name;
  }

  /// The `tmux attach -t <target>` line shown in the exit hint. Empty when not
  /// in tmux or the target can't be derived.
  String get attachLine {
    final target = attachTarget;
    return target.isEmpty ? '' : 'tmux attach -t $target';
  }

  /// The one-line hint shown by `/detach` (and Alt+D) when NOT in tmux. The
  /// exact string is the user-facing contract — don't reword without updating
  /// docs/features/session_attach_detach.md and the README.
  static const String notInTmuxHint =
      'not running in tmux — start tina with: tmux new -s tina  (then /detach works)';

  /// Run `tmux detach-client` so the calling client returns to the shell while
  /// the tina process (and its agent) keeps running inside the tmux server.
  /// Returns true on a clean detach. Any spawn failure (tmux missing, the
  /// socket gone) is surfaced by the returned [detachError] and never thrown —
  /// a detach is a convenience, not a correctness path: a failed detach
  /// must not crash the REPL or the exit path.
  Future<({bool ok, String? error})> detach() async {
    if (!inTmux) {
      return (ok: false, error: notInTmuxHint);
    }
    try {
      final result = await processRunner.run('tmux', ['detach-client']);
      if (result.exitCode == 0) return (ok: true, error: null);
      return (ok: false, error: result.stderr.trim().isEmpty
          ? 'tmux detach-client exited ${result.exitCode}'
          : result.stderr.trim());
    } on ProcessException catch (e) {
      return (ok: false, error: e.message);
    } on FileSystemException catch (e) {
      return (ok: false, error: e.message);
    } catch (e) {
      // Any other runner failure (an odd spawn error, a non-ProcessException
      // throw from the seam) — report, never propagate.
      return (ok: false, error: '$e');
    }
  }

  // -- Once-per-install "rendering" notice ----------------------------------
  //
  // The notcurses backend (the default) renders inside tmux less predictably
  // than the ANSI one. Rather than nag on every start, a single dim notice
  // drops into the chat the first time a tmux run happens per install —
  // tracked by a hidden marker under ~/.tina (the same convention as the
  // summaries sidecar's `.proposal_shown`).

  /// The hidden marker file that records the notice was shown.
  File get markerFile => File(p.join(tinaDir.path, '.tmux_notice_shown'));

  /// Whether the one-time tmux notice has already been shown for this install.
  bool get tmuxNoticeShown => markerFile.existsSync();

  /// Record that the notice was shown. Best-effort: a failed write (read-only
  /// ~/.tina, permissions) is swallowed — worst case the notice appears once
  /// more next tmux run.
  void markTmuxNoticeShown() {
    try {
      markerFile.parent.createSync(recursive: true);
      markerFile.writeAsStringSync('${DateTime.now().toIso8601String()}\n');
    } on FileSystemException {
      // Ignored by design (see the marker's doc comment).
    }
  }

  /// The once-per-install dim notice, when it should be shown: running inside
  /// tmux, on the notcurses backend (the one that renders less predictably
  /// there), and not yet shown. Returns null otherwise.
  String? tmuxAttachNotice({required bool notcursesBackend}) {
    if (!inTmux || !notcursesBackend || tmuxNoticeShown) return null;
    return 'running under tmux: `--backend ansi` renders more predictably '
        'inside tmux than the notcurses default\n';
  }
}