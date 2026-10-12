import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';

/// Attachment-local ordinary question UI. Answers always name their request;
/// disposing an input capture or detaching never supplies an answer.
final class QuestionView implements ConsoleContribution {
  QuestionView(this.client);
  final QuestionClient client;
  ConsoleContext? _context;
  void Function()? _unlisten;
  final _pending = <String, _Draft>{};
  void Function()? _paint;

  @override
  void attachConsole(ConsoleContext context) {
    if (_context != null) throw StateError('question view already attached');
    _context = context;
    _unlisten = client.listen((questions) {
      final ids = questions.map((q) => q.id).toSet();
      for (final entry in _pending.entries.toList()) {
        if (!ids.contains(entry.key)) {
          entry.value.close();
          _pending.remove(entry.key);
        }
      }
      for (final question in questions) {
        if (_pending.containsKey(question.id)) continue;
        final draft = _Draft(question);
        _pending[question.id] = draft;
        if (client.canAnswer) {
          unawaited(_present(context, draft));
        } else {
          context.chat
              .writeln('Waiting for answer: ${_plain(question.prompt)}');
        }
      }
    });
  }

  bool _active(ConsoleContext context, _Draft draft) =>
      identical(_context, context) &&
      !draft.closed.isCompleted &&
      client.pending.any((question) => question.id == draft.question.id);

  Future<void> _present(ConsoleContext context, _Draft draft) async {
    try {
      await context.interactIf(() => _active(context, draft), () async {
        final input = context.openInputSession(
            globalKeys: true,
            panelNavigation: false,
            cancelSignal: draft.closed.future);
        final overlay = OverlayRegion(context.screen, Rect.empty);
        final cursor = context.screen.claimCursor();
        var disposed = false;
        void dispose() {
          if (disposed) return;
          disposed = true;
          input.dispose();
          cursor.release();
          overlay.dispose();
        }

        draft.dispose = dispose;
        var edit = const TextLineInput();
        var top = 0, page = 1;
        void paint() {
          final screen = context.screen;
          final bounds = dialogBounds(screen.layout,
              preferredWidth: 90, preferredHeight: 14);
          final framed = bounds.width >= 4 && bounds.height >= 6;
          final width = (bounds.width - (framed ? 4 : 0)).clamp(0, 90);
          page = (bounds.height - (framed ? 5 : 1)).clamp(0, 14);
          final rows = wrapDialogWords(_plain(draft.question.prompt), width);
          top = top.clamp(0, (rows.length - page).clamp(0, rows.length));
          final prompt = rows.skip(top).take(page).toList();
          final field = textFieldView(edit, width: width);
          final footer = 'Enter answer · Esc cancel · PgUp/PgDn scroll';
          final lines = framed
              ? dialogBoxLines(
                  width: bounds.width,
                  height: bounds.height,
                  title: 'Session question',
                  body: [...prompt, field.text],
                  footer: footer,
                  paint: (text) =>
                      screen.colorize(screen.theme.border.focus, text))
              : [...prompt, field.text].take(bounds.height).toList();
          screen.frame(() {
            overlay.update(bounds: bounds, lines: lines);
            if (bounds.height > 0 && width > 0) {
              cursor.place(bounds.row + (framed ? 1 : 0) + prompt.length,
                  bounds.col + (framed ? 2 : 0) + field.cursorColumn);
            }
          });
        }

        _paint = paint;
        try {
          context.requestAttention();
          while (_active(context, draft)) {
            paint();
            final event = await input.read();
            if (!_active(context, draft)) break;
            switch (event) {
              case EscapeKey():
                client.dismiss(draft.question.id);
                return;
              case ControlKey(code: ControlCode.ctrlC):
                // Global quit/disposed input is a detach, not a response.
                return;
              case ControlKey(code: ControlCode.enter):
                client.answer(draft.question.id, edit.buffer);
                return;
              case CharInput(:final text):
              case PasteInput(:final text):
                edit = edit.insert(_plain(text));
              case ControlKey(code: ControlCode.backspace):
                edit = edit.backspace();
              case ArrowKey(
                  direction: ArrowDirection.left,
                  :final hasAlt,
                  :final hasCtrl
                ):
                edit =
                    hasAlt || hasCtrl ? edit.moveWordLeft() : edit.moveLeft();
              case ArrowKey(
                  direction: ArrowDirection.right,
                  :final hasAlt,
                  :final hasCtrl
                ):
                edit =
                    hasAlt || hasCtrl ? edit.moveWordRight() : edit.moveRight();
              case ArrowKey(direction: ArrowDirection.pageUp):
                top = (top - page).clamp(0, top);
              case ArrowKey(direction: ArrowDirection.pageDown):
                top += page;
              case EditingKey(action: EditingAction.home):
                edit = edit.moveHome();
              case EditingKey(action: EditingAction.end):
                edit = edit.moveEnd();
              case EditingKey(action: EditingAction.delete):
                edit = edit.deleteForward();
              case EditingKey(action: EditingAction.killToStart):
                edit = edit.killToStart();
              case EditingKey(action: EditingAction.killToEnd):
                edit = edit.killToEnd();
              case EditingKey(action: EditingAction.deleteWordBackward):
                edit = edit.killWordBackward();
              case EditingKey(action: EditingAction.deleteWordForward):
                edit = edit.killWordForward();
              default:
                break;
            }
          }
        } finally {
          if (identical(_paint, paint)) _paint = null;
          dispose();
          draft.dispose = null;
        }
      });
    } catch (_) {
      // A failed presenter has no authority to answer a shared question.
    } finally {
      if (identical(_pending[draft.question.id], draft)) {
        _pending.remove(draft.question.id);
      }
    }
  }

  @override
  void repaintConsole() => _paint?.call();
  @override
  void detachConsole() {
    _unlisten?.call();
    _unlisten = null;
    _context = null;
    _paint = null;
    for (final draft in _pending.values) draft.close();
    _pending.clear();
  }
}

String _plain(String value) =>
    value.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');

final class _Draft {
  _Draft(this.question);
  final SessionQuestion question;
  final closed = Completer<void>();
  void Function()? dispose;
  void close() {
    if (!closed.isCompleted) closed.complete();
    dispose?.call();
  }
}
