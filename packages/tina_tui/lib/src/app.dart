/// The full-screen render loop: the one place tina_tui owns a terminal.
///
/// The assembly is already built and wired when [runApp] is called —
/// config read, provider built, plugins mounted, approver registered.
/// This file opens the screen (`tina_console`, the only terminal path),
/// puts the app's [TuiTerminal] view in the services locator **before**
/// anything can read it, paints what the assembly already knows, and
/// pumps: [LineEditor.readLine] owns the keystrokes, each line goes
/// through [TuiSession.runLine] — the same dispatch the assembly
/// guarantees — and the outcome lands in the chat region. While an
/// approval question is open the question repaints itself on every
/// selection move; the dialog's own key source decides where keys come
/// from in production.
///
/// Everything is injectable — [Stdio] carries the bytes and the writes,
/// so a test drives a fake and the TTY runs the [LiveStdio] path. No
/// decision lives here: the assembly owns the wiring, `tina_console`
/// owns the pixels, the dialog owns the ask.
library;

import 'dart:io' show stdin, stdout;

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_services/tina_services.dart';

import 'approval_approver.dart';
import 'approval_dialog.dart';
import 'tui_session.dart';

/// Run the app on [session] until the user quits or stdin ends.
///
/// The named seams exist for tests: [screen] replaces the real
/// full-screen one, [editorFor] replaces the raw-mode line editor and
/// [keys] replaces where the dialog's keys come from (the approver
/// wiring itself is the session's and always runs). Returns 0 — the
/// process exits nonzero only on a startup failure, before this runs.
Future<int> runApp(
  TuiSession session, {
  Screen? screen,
  LineEditor Function(Screen screen)? editorFor,
  KeySource Function()? keys,
}) async {
  final s = screen ?? _newScreen();
  // The question overlay, created against the screen this run owns.
  final overlay = OverlayRegion(
    s,
    Rect(row: 1, col: 1, width: 1, height: 1),
  );
  // The session's terminal — reused when the session already has one
  // (TuiSession.wrap put it there; a test may have too), created and
  // registered here when the slot is empty. Either way: exactly one
  // terminal in the slot before anything reads it.
  final existing = session.services.maybe<Terminal>();
  final terminal = existing is TuiTerminal ? existing : TuiTerminal();
  // Every line the session's plugins tell is painted into the chat
  // region inside its own frame — the only screen writes outside the
  // loop below.
  terminal.onLine = (line) => s.frame(() => s.chat.writeln(line));
  session.services.put<Terminal>(terminal);

  // The editor owns the raw bytes; where its keys go is decided below.
  // Late because the asker's key closure reads it on demand, long after
  // the assignment below runs.
  late final LineEditor editor =
      editorFor != null ? editorFor(s) : LineEditor(screen: s);

  // The dialog asker — wired once, here, before the editor is built:
  // the sandbox's questions are answered by the dialog through [keys]
  // (the editor's serialized key reader in production, an injected
  // source in tests). Nothing here swallows a question: no keys, no
  // decision.
  final asker = QueuedDialogAsker(
    dialogFor: (ask) => ApprovalDialog(
      null,
      ask: ApprovalAskContext(ask.op, ask.path, ask.reason),
    ),
    keysFor: () => keys?.call() ?? _EditorKeys(editor),
  );
  session.wireApprovers(asker);

  // Paint or clear the question overlay for the current ask, if any.
  // Wired as the asker's onChange, so an ask paints the moment it opens
  // and repaints on every selection move; the loop also calls it after
  // each line so ordering can never matter.
  void syncDialog() {
    final ask = asker.current;
    if (ask == null) {
      overlay.hide();
      return;
    }
    final dialog = ApprovalDialog(
      null,
      ask: ApprovalAskContext(ask.op, ask.path, ask.reason),
    );
    final rows = dialog.rows(width: s.layout.chat.width - 4);
    final text = [for (final r in rows) r.runs.map((run) => run.text).join()];
    overlay.update(bounds: _boxFor(s, text), lines: text);
  }

  asker.onChange = syncDialog;

  var ownsTty = false;
  try {
    // Raw mode only when this loop opened the real screen and there is
    // a controlling terminal; tolerantly skipped everywhere else — a
    // test harness drives events by hand and has no tty to change. An
    // injected screen still renders (alt screen below), it just never
    // touches the process's tty.
    ownsTty = screen == null && s.io.hasTerminal;
    if (ownsTty) {
      try {
        stdin.echoMode = false;
        stdin.lineMode = false;
      } catch (_) {}
    }
    if (!s.passthrough) s.enterAltScreen();

    // First paint: what the assembly already knows — the config note it
    // read, the resumed log it seeded — then the status strip and the
    // empty input row, all in one frame.
    s.frame(() {
      final note = session.assembly.configNote;
      if (note != null) s.chat.writeln(note);
      for (final e in session.host.session.loop.log) {
        final line = _entryLine(e);
        if (line != null) s.chat.writeln(line);
      }
      _paintStatus(s, session, busy: false);
      s.input.render(prompt: '› ', buffer: '', cursor: 0);
    });

    while (true) {
      if (session.assembly.quitRequested) break;
      _paintStatus(s, session, busy: false);
      syncDialog();
      final line = await editor.readLine('› ');
      if (line == null) break; // stdin closed
      if (line.isEmpty) continue;
      _paintStatus(s, session, busy: true);
      await session.runLine(line);
      // An ask opened during the turn (or a /mode tell landed):
      // repaint once, then return to the editor — the asker's onChange
      // handles the rest.
      syncDialog();
    }
    return 0;
  } finally {
    overlay.hide();
    if (ownsTty) {
      try {
        stdin.echoMode = true;
        stdin.lineMode = true;
      } catch (_) {}
    }
    if (!s.passthrough) s.leaveAltScreen();
    editor.close();
    session.close();
  }
}

/// Where a dialog's keys come from in production: the editor's
/// serialized [LineEditor.readKey]. Arrows and Enter answer; Esc
/// denies (the dialog's own cancel). Ctrl+C unwinds the read — read as
/// a denial with everything else, because a dialog mid-question is
/// never the place to kill the session.
final class _EditorKeys implements KeySource {
  _EditorKeys(this._editor);

  final LineEditor _editor;
  Future<void>? _cancel;

  @override
  Future<ApprovalKey?> next() async {
    final event = await _editor.readKey(globalKeys: true,
        cancelSignal: _cancel ??= _editor.inputCancelled);
    return switch (event) {
      ArrowKey(direction: ArrowDirection.up) => ApprovalKey.up,
      ArrowKey(direction: ArrowDirection.down) => ApprovalKey.down,
      ControlKey(code: ControlCode.enter) => ApprovalKey.confirm,
      ControlKey(code: ControlCode.ctrlC) => ApprovalKey.cancel,
      EscapeKey() => ApprovalKey.cancel,
      _ => null, // not a dialog key — do not dispatch, wait again
    };
  }
}

/// The centered box the dialog paints into: as wide as the widest row,
/// tall enough for every row, centered on screen.
Rect _boxFor(Screen s, List<String> rows) {
  final width = rows.fold(0, (m, r) => r.length > m ? r.length : m);
  final height = rows.length;
  return Rect(
    row: (s.layout.chat.height - height) ~/ 2,
    col: (s.layout.chat.width - width) ~/ 2,
    width: width,
    height: height,
  );
}

/// The status strip: the mode word the assembly's service carries, then
/// the busy marker while a turn runs.
void _paintStatus(Screen s, TuiSession session, {required bool busy}) {
  final label = 'mode: ${session.modeWord}${busy ? '  ·  thinking…' : ''}';
  s.status.writeAt(0, label);
}

/// The one line a resumed log entry renders as — or null when the entry
/// is bookkeeping a restart need not replay (tool traffic, turn ends).
String? _entryLine(SessionEntry e) {
  if (e is InputRecordedEntry) return 'you: ${e.text}';
  if (e is MessageAppendedEntry && e.message.role == Role.assistant) {
    final text = [
      for (final b in e.message.content)
        if (b is TextBlock) b.text,
    ].join();
    return text.isEmpty ? null : 'tina: $text';
  }
  return null;
}

/// The real screen: size off the process's stdout, ANSI backend, no
/// menu bar — one chat panel, one status row, one input row. Without a
/// terminal there is no size to ask for (`terminalColumns` throws on a
/// pipe), so debug and CI runs fall back to a conventional 80×24.
Screen _newScreen() {
  var columns = 80;
  var lines = 24;
  if (stdout.hasTerminal) {
    columns = stdout.terminalColumns;
    lines = stdout.terminalLines;
  }
  return Screen(
    io: const LiveStdio(),
    layout: ScreenLayout.fromSize(columns, lines),
  );
}
