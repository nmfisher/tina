library;

import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_console/tina_console.dart';
import 'src/approval_dialog.dart';
import 'src/command_pattern_review.dart';
export 'src/approval_dialog.dart';
export 'src/command_pattern_review.dart';

/// One attachment's dialog, regex draft, input capture and overlay state.
final class ApprovalView implements ConsoleContribution {
  ApprovalView(this.interaction);
  final ApprovalInteraction interaction;
  void Function()? _unlisten;
  QueuedDialogAsker? get asker => _asker;
  QueuedDialogAsker? _asker;
  ConsoleContext? _context;
  OverlayRegion? _overlay;
  ScreenCursor? _cursor;
  ApprovalRequest? _alertedRequest;

  @override
  void attachConsole(ConsoleContext context) {
    if (_context != null) throw StateError('approval view already attached');
    _context = context;
    _overlay = OverlayRegion(
        context.screen, Rect(row: 1, col: 1, width: 1, height: 1));
    _asker = QueuedDialogAsker(
        suggestCommandPattern: interaction.suggest, denyOnClose: false)
      ..onChange = repaintConsole;
    _unlisten = context.own(interaction.listen((question) {
      unawaited(_present(question));
    }));
  }

  Future<void> _present(ApprovalQuestion ticket) async {
    final asker = _asker;
    final context = _context;
    if (asker == null || context == null) return;
    await context.interact(() async {
      if (!ticket.isActive || !identical(context, _context)) return;
      final input = context.openInputSession(
          globalKeys: true,
          panelNavigation: false,
          acceptPaste: false,
          releaseOnEscape: true,
          cancelSignal:
              Future.any([ticket.done.then((_) {}), asker.whenClosed]));
      final cursor = context.screen.claimCursor();
      _cursor = cursor;
      try {
        await asker.ask(ticket, keys: _ConsoleKeys(input));
      } finally {
        input.dispose();
        cursor.release();
        if (identical(_cursor, cursor)) _cursor = null;
      }
    });
  }

  @override
  void repaintConsole() {
    final context = _context;
    final dialog = _asker?.currentDialog;
    if (context == null) return;
    if (dialog == null) {
      _alertedRequest = null;
      _hide(context);
      return;
    }
    final screen = context.screen;
    final input = screen.input.bounds;
    final height =
        (input.row - screen.layout.chat.row + 1).clamp(0, screen.layout.height);
    final review = _asker?.currentPatternReview;
    final rows = review?.rows(
            width: input.width, height: height, theme: screen.theme) ??
        dialog.rows(width: input.width, height: height, theme: screen.theme);
    final lines = [
      for (final row in rows)
        row.runs
            .map((r) =>
                r.code == null ? r.text : screen.colorize(r.code!, r.text))
            .join()
    ];
    final bounds = Rect(
        row: input.row - lines.length + 1,
        col: input.col,
        width: input.width,
        height: lines.length);
    screen.frame(() {
      final previous = _overlay!.bounds;
      if (_overlay!.isVisible &&
          (previous.row != bounds.row ||
              previous.col != bounds.col ||
              previous.width != bounds.width ||
              previous.height != bounds.height)) {
        _overlay!.hide();
        screen.chat.repaint();
      }
      _overlay!.update(bounds: bounds, lines: lines);
      if (review?.cursor case final position?) {
        _cursor?.place(bounds.row + position.$1, bounds.col + position.$2);
      } else {
        _cursor?.hide();
      }
    });
    final request = _asker!.current;
    if (request != null && !identical(request, _alertedRequest)) {
      _alertedRequest = request;
      context.requestAttention();
    }
  }

  void _hide(ConsoleContext context) {
    if (_overlay?.isVisible != true) return;
    context.screen.frame(() {
      _overlay!.hide();
      context.chat.repaint();
      context.screen.input.repaint();
      context.refreshInput();
    });
  }

  @override
  void detachConsole() {
    _unlisten?.call();
    _unlisten = null;
    _asker?.close();
    if (_context case final context?) _hide(context);
    _overlay?.dispose();
    _cursor?.release();
    _cursor = null;
    _asker = null;
    _overlay = null;
    _context = null;
    _alertedRequest = null;
  }
}

/// Serializes dialogs while allowing cancelled queued requests to disappear.
final class QueuedDialogAsker {
  QueuedDialogAsker(
      {this.keysFor, this.suggestCommandPattern, this.denyOnClose = true});
  final bool denyOnClose;
  final _cancel = Completer<void>();
  Future<void> get whenClosed => _cancel.future;
  final KeySource Function(ApprovalQuestion)? keysFor;
  final SuggestCommandPattern? suggestCommandPattern;
  final _pending = <ApprovalQuestion>{};
  Future<void> _tail = Future.value();
  ApprovalRequest? current;
  ApprovalDialog? currentDialog;
  CommandPatternReview? currentPatternReview;
  void Function()? onChange;
  bool _closed = false;

  Future<void> ask(ApprovalQuestion ticket, {KeySource? keys}) {
    if (_closed) {
      if (denyOnClose) ticket.respond(ApprovalDecision.deny);
      return Future.value();
    }
    _pending.add(ticket);
    final run = _tail.then((_) async {
      if (_closed || !ticket.isActive) return;
      final request = ticket.request;
      final dialog = ApprovalDialog(null,
          ask: ApprovalAskContext(
              request.operation, request.target, request.reason,
              details: request.details,
              confirmation: request.kind == ApprovalKind.confirmation));
      current = request;
      currentDialog = dialog;
      try {
        final source = keys ?? keysFor?.call(ticket);
        if (source == null) throw StateError('approval has no input source');
        onChange?.call();
        // Repaint on EVERY key, recognized or not. An approval dialog owns
        // the keyboard while it is open; unrecognized keys (ordinary typing,
        // a paste) are consumed as no-ops. Without a repaint the dialog
        // looks frozen — the user types and nothing on screen changes,
        // because the dialog is silently eating their keys. The repaint
        // re-asserts the answer selector (and its cursor) so each keypress
        // visibly lands, making the dialog's keyboard ownership legible.
        while (ticket.isActive && !_closed) {
          final outcome = await dialog.awaitDecision(
              _CancellableKeys(source, ticket, whenClosed),
              onKey: onChange,
              onAnyKey: onChange);
          if (_closed || !ticket.isActive) break;
          if (!outcome.editCommandPattern) {
            ticket.respond(outcome.decision);
            break;
          }
          if (source is! CommandPatternKeySource) continue;
          final review = CommandPatternReview(request,
              suggest: suggestCommandPattern, onChange: onChange);
          currentPatternReview = review;
          try {
            var back = false;
            while (ticket.isActive && !_closed && !back) {
              source.editingPattern(!review.reviewing);
              onChange?.call();
              final event = await Future.any([
                source.nextEvent(),
                ticket.done.then<InputEvent?>((_) => null),
                whenClosed.then<InputEvent?>((_) => null)
              ]);
              if (event == null || !ticket.isActive || _closed) break;
              switch (review.handle(event)) {
                case CommandPatternReviewResult.pending:
                  break;
                case CommandPatternReviewResult.back:
                  back = true;
                case CommandPatternReviewResult.denied:
                  ticket.respond(ApprovalDecision.deny);
                case CommandPatternReviewResult.approved:
                  final answer = review.outcome;
                  ticket.respond(answer.decision,
                      commandPattern: answer.commandPattern);
              }
            }
          } finally {
            review.close();
            currentPatternReview = null;
            source.editingPattern(false);
          }
        }
      } catch (_) {
        if (!_closed) ticket.respond(ApprovalDecision.deny);
      } finally {
        currentPatternReview?.close();
        currentPatternReview = null;
        current = null;
        currentDialog = null;
        onChange?.call();
      }
    }).whenComplete(() => _pending.remove(ticket));
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cancel.complete();
    currentPatternReview?.close();
    onChange = null;
    if (denyOnClose) {
      for (final ticket in _pending.toList())
        ticket.respond(ApprovalDecision.deny);
    }
  }
}

final class _CancellableKeys implements KeySource {
  _CancellableKeys(this.inner, this.ticket, this.cancelled);
  final Future<void> cancelled;
  final KeySource inner;
  final ApprovalQuestion ticket;
  @override
  Future<ApprovalKey?> next() {
    if (!ticket.isActive) return Future.value(null);
    return Future.any([
      inner.next(),
      ticket.done.then<ApprovalKey?>((_) => null),
      cancelled.then<ApprovalKey?>((_) => null)
    ]);
  }
}

final class _ConsoleKeys implements CommandPatternKeySource {
  _ConsoleKeys(this.input);
  final InputSession input;
  @override
  Future<InputEvent?> nextEvent() => input.read();
  @override
  void editingPattern(bool editing) =>
      input.configure(acceptPaste: editing, releaseOnEscape: false);
  @override
  Future<ApprovalKey?> next() async {
    input.configure(acceptPaste: false, releaseOnEscape: true);
    while (true) {
      final event = await input.read();
      final key = switch (event) {
        CharInput(text: 'y') => ApprovalKey.allow,
        CharInput(text: 'n') => ApprovalKey.deny,
        CharInput(text: 'a') => ApprovalKey.always,
        CharInput(text: 'p') => ApprovalKey.workspace,
        CharInput(text: 'g') => ApprovalKey.global,
        CharInput(text: 'e') => ApprovalKey.editCommandPattern,
        CharInput(text: 'r') => ApprovalKey.toggleReadDirectory,
        CharInput(text: 'w') => ApprovalKey.toggleWriteDirectory,
        CharInput(text: ' ') => ApprovalKey.toggleDirectory,
        ArrowKey(direction: ArrowDirection.pageUp) => ApprovalKey.pageUp,
        ArrowKey(direction: ArrowDirection.pageDown) => ApprovalKey.pageDown,
        ScrollEvent(:final up) =>
          up ? ApprovalKey.scrollUp : ApprovalKey.scrollDown,
        ArrowKey(direction: ArrowDirection.up) => ApprovalKey.up,
        ArrowKey(direction: ArrowDirection.down) => ApprovalKey.down,
        ArrowKey(direction: ArrowDirection.left) => ApprovalKey.up,
        ArrowKey(direction: ArrowDirection.right) => ApprovalKey.down,
        ControlKey(code: ControlCode.enter) => ApprovalKey.confirm,
        ControlKey(code: ControlCode.tab) => ApprovalKey.details,
        ControlKey(code: ControlCode.ctrlC) => ApprovalKey.cancel,
        EscapeKey() => ApprovalKey.cancel,
        _ => null,
      };
      if (key != null) return key;
    }
  }
}
