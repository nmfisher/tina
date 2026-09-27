/// The bridge that lets the approval dialog answer the sandbox's questions.
///
/// The sandbox asks through the `Approver` typedef — an injectable async
/// function — and is fail-closed: with nothing wired, a write outside the
/// project root is refused ("no approver is wired"). This file supplies the
/// wired answer: a [DialogApprover] adapts the sandbox's vocabulary
/// (`FileOperation`, `Approval`) to the dialog's ([PendingFileAsk],
/// [ApprovalOutcome]), so the decision stays where it already is —
/// [ApprovalDialog.awaitDecision] over a [KeySource] — and the sandbox keeps
/// owning everything else:
///
/// - **Remembering "always"** is the sandbox's business
///   (`grants.remember`, verdict short-circuit). The dialog returns a
///   decision; it never records grants.
/// - **One decision at a time**: [QueuedDialogAsker] serializes asks. A
///   second question while one is open waits in line; nothing interleaves
///   on one key source.
/// - **Testable without a terminal**: the decision is anything that
///   fulfills [ApprovalAsker] — [ScriptedKeySource] in tests, a raw-mode
///   host in production. The drawing stays in [ApprovalDialog.rows].
library;

import 'package:tina_tools/tina_tools.dart';

import 'approval_dialog.dart';

/// One pending question, phrased for a person: what the sandbox resolved
/// the operation to (canonical path — `../` and symlink escapes are judged
/// on where they really land) and why it is asking.
final class PendingFileAsk {
  /// The resolved operation: `FileOp.read` or `FileOp.write` on a
  /// canonical path.
  final FileOperation request;

  /// The reason the table produced an ask (e.g. "outside the project
  /// root"), already worded for the model's transcript — shown verbatim.
  final String reason;

  const PendingFileAsk(this.request, this.reason);

  FileOp get op => request.op;
  String get path => request.path;
}

/// The decision half of the dialog, abstracted from its drawing: given a
/// pending ask, eventually an outcome. Cancelled or closed means deny —
/// [ApprovalDialog.awaitDecision] already guarantees that.
abstract interface class ApprovalAsker {
  Future<ApprovalOutcome> ask(PendingFileAsk ask);
}

/// Answers every ask through an [ApprovalDialog] driven by a [KeySource].
/// Both are built per ask: the dialog is stateful per question (selection,
/// pending call), and the key source is where a raw-mode host plugs in.
class QueuedDialogAsker implements ApprovalAsker {
  /// Builds the dialog for one ask — the pending call the view renders.
  final ApprovalDialog Function(PendingFileAsk ask) dialogFor;

  /// Builds the key source for one ask. Production: the host's raw-mode
  /// parser. Tests: a [ScriptedKeySource].
  final KeySource Function() keysFor;

  /// Ask n+1 waits here until ask n resolves.
  Future<void> _tail = Future.value();

  QueuedDialogAsker({required this.dialogFor, required this.keysFor});

  @override
  Future<ApprovalOutcome> ask(PendingFileAsk ask) {
    // One decision at a time: chain onto the previous ask. If anything
    // upstream throws, keep the chain alive so later asks still run.
    final run = _tail.then((_) async {
      final dialog = dialogFor(ask);
      return dialog.awaitDecision(keysFor());
    });
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }
}

/// The sandbox's [Approver], answered by the TUI. Adapts the vocabulary and
/// enforces fail-closed on this side too: a denied or cancelled dialog
/// throws [SandboxViolation] — the refusal the model reads — with the same
/// reason the table produced. `always` is returned, never remembered here;
/// the sandbox records the grant.
final class DialogApprover {
  final ApprovalAsker _asker;

  DialogApprover(this._asker);

  /// The [Approver] the sandbox receives — the [approve] tearoff, its
  /// signature checked against the typedef right here.
  Approver get fn => approve;

  Future<Approval> approve(FileOperation request, String reason) async {
    final ask = PendingFileAsk(request, reason);
    final outcome = await _asker.ask(ask);
    return switch (outcome.decision) {
      ApprovalDecision.allow => Approval.yes,
      ApprovalDecision.allowAlways => Approval.always,
      ApprovalDecision.deny => throw SandboxViolation(outcome.isCancellation
          ? '$reason — denied by the user (cancelled: the dialog was '
              'closed or escape pressed)'
          : '$reason — denied by the user'),
    };
  }
}
