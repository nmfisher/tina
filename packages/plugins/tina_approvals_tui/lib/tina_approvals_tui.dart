library;

import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'src/approval_dialog.dart';
export 'src/approval_dialog.dart';

PluginDefinition<C> approvalTuiDefinition<C>() =>
    PluginDefinition<C>('tina/approvals-tui', (_) => ApprovalTuiPlugin(),
        provides: [approvalChannel]);

/// The channel owns presentation; the application mounts it like any other
/// console contribution. No application or tools-package import is required.
final class ApprovalTuiPlugin extends AgentPlugin
    implements ApprovalChannel, ConsoleContribution {
  @override
  String get id => 'tina/approvals-tui';
  QueuedDialogAsker? get asker => _asker;
  QueuedDialogAsker? _asker;
  ConsoleContext? _context;
  OverlayRegion? _overlay;
  bool _closed = false;

  @override
  void attachConsole(ConsoleContext context) {
    if (_closed || _context != null)
      throw StateError('approval channel already attached or closed');
    _context = context;
    _overlay = OverlayRegion(
        context.screen, Rect(row: 1, col: 1, width: 1, height: 1));
    _asker = QueuedDialogAsker(
        keysFor: (ticket) => _ConsoleKeys(context, ticket.done.then((_) {})))
      ..onChange = repaintConsole;
  }

  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    final asker = _asker;
    if (_closed || asker == null) {
      ticket.respond(ApprovalDecision.deny);
      return;
    }
    await asker.ask(ticket);
  }

  @override
  void repaintConsole() {
    final context = _context;
    final dialog = _asker?.currentDialog;
    if (context == null) return;
    if (dialog == null) {
      _overlay?.hide();
      return;
    }
    final area = dialogArea(context.screen.layout);
    final rows = dialog.rows(width: area.width, height: area.height);
    final lines = [for (final row in rows) row.runs.map((r) => r.text).join()];
    _overlay!.update(
        bounds: centeredDialog(context.screen.layout, lines), lines: lines);
  }

  @override
  void detachConsole() {
    _asker?.close();
    _overlay?.hide();
    _asker = null;
    _overlay = null;
    _context = null;
  }

  @override
  void closeSession() {
    _closed = true;
    detachConsole();
  }
}

/// Serializes dialogs while allowing cancelled queued requests to disappear.
final class QueuedDialogAsker {
  QueuedDialogAsker({required this.keysFor});
  final KeySource Function(ApprovalTicket) keysFor;
  final _pending = <ApprovalTicket>{};
  Future<void> _tail = Future.value();
  ApprovalRequest? current;
  ApprovalDialog? currentDialog;
  void Function()? onChange;
  bool _closed = false;

  Future<void> ask(ApprovalTicket ticket) {
    if (_closed) {
      ticket.respond(ApprovalDecision.deny);
      return Future.value();
    }
    _pending.add(ticket);
    final run = _tail.then((_) async {
      if (_closed || !ticket.isActive) return;
      final request = ticket.request;
      final dialog = ApprovalDialog(null,
          ask: ApprovalAskContext(
              request.operation, request.target, request.reason));
      current = request;
      currentDialog = dialog;
      try {
        onChange?.call();
        final outcome = await dialog.awaitDecision(
            _CancellableKeys(keysFor(ticket), ticket),
            onKey: onChange);
        ticket.respond(outcome.decision);
      } catch (_) {
        ticket.respond(ApprovalDecision.deny);
      } finally {
        current = null;
        currentDialog = null;
        onChange?.call();
      }
    }).whenComplete(() => _pending.remove(ticket));
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  void close() {
    _closed = true;
    for (final ticket in _pending.toList()) {
      ticket.respond(ApprovalDecision.deny);
    }
  }
}

final class _CancellableKeys implements KeySource {
  _CancellableKeys(this.inner, this.ticket);
  final KeySource inner;
  final ApprovalTicket ticket;
  @override
  Future<ApprovalKey?> next() {
    if (!ticket.isActive) return Future.value(null);
    return Future.any(
        [inner.next(), ticket.done.then<ApprovalKey?>((_) => null)]);
  }
}

final class _ConsoleKeys implements KeySource {
  _ConsoleKeys(this.context, this.cancelled);
  final ConsoleContext context;
  final Future<void> cancelled;
  @override
  Future<ApprovalKey?> next() async {
    while (true) {
      final event = await context.readKey(cancelled);
      final key = switch (event) {
        ArrowKey(direction: ArrowDirection.up) => ApprovalKey.up,
        ArrowKey(direction: ArrowDirection.down) => ApprovalKey.down,
        ControlKey(code: ControlCode.enter) => ApprovalKey.confirm,
        ControlKey(code: ControlCode.tab) => ApprovalKey.details,
        ControlKey(code: ControlCode.ctrlC) => ApprovalKey.cancel,
        EscapeKey() => ApprovalKey.cancel,
        null => ApprovalKey.cancel,
        _ => null,
      };
      if (key != null) return key;
    }
  }
}
