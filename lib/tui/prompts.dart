import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_engine/invocation.dart' as engine show Invocation;

/// One keyboard owner per editor. Prompt state stays in its form while held;
/// suspension releases the key reader without answering the form.
class Prompts {
  static final _instances = Expando<Prompts>();
  static Prompts of(LineEditor editor) =>
      _instances[editor] ??= Prompts._(editor);
  final LineEditor editor;
  final _sessions = <PromptSession>[];
  Prompts._(this.editor);

  PromptSession? get active {
    final available = _sessions.where(
      (s) => !s.cancelled && !s.closed && s.invocation?.isHeld != true,
    );
    return available.where((s) => s.priority).firstOrNull ??
        available.firstOrNull;
  }

  PromptSession open({Future<void>? cancelSignal, bool priority = false}) {
    final session = PromptSession._(
      this,
      InvocationContext.current?.invocation,
      priority,
    );
    session.cancelled =
        session.invocation?.isCancelled == true ||
        session.invocation?.isDone == true;
    _sessions.add(session);
    session._detach = session.invocation?.listen(_refresh);
    for (final signal in [
      editor.inputCancelled,
      if (cancelSignal != null) cancelSignal,
      if (session.invocation != null) session.invocation!.cancelSignal,
    ]) {
      signal.then((_) {
        if (session.closed) return;
        session.cancelled = true;
        _refresh();
      });
    }
    _refresh();
    return session;
  }

  void _refresh() {
    for (final session in _sessions) {
      if (session.invocation?.isCancelled == true ||
          session.invocation?.isDone == true) {
        session.cancelled = true;
      }
    }
    final selected = active;
    for (final session in _sessions.toList()) {
      session._update(identical(selected, session));
    }
  }
}

class PromptSession {
  final Prompts owner;
  final engine.Invocation? invocation;
  final bool priority;
  bool cancelled = false;
  bool closed = false;
  bool _active = false;
  Completer<void> _changed = Completer<void>();
  void Function()? _paint;
  void Function()? _hide;
  void Function()? _detach;
  PromptSession._(this.owner, this.invocation, this.priority);
  bool get isActive => _active && !closed && !cancelled;
  void attach({required void Function() paint, required void Function() hide}) {
    _paint = paint;
    _hide = hide;
  }

  void _update(bool active) {
    if (active == _active && !cancelled) return;
    _active = active;
    if (!active) _hide?.call();
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
    if (active) _paint?.call();
  }

  Future<InputEvent> read() async {
    while (!closed && !cancelled) {
      if (!isActive) {
        await _changed.future;
        continue;
      }
      _paint?.call();
      final changed = _changed;
      final event = await owner.editor.readKey(
        globalKeys: true,
        panelNavigation: false,
        cancelSignal: changed.future,
      );
      // A cancelled key read caused by suspension is never a user answer.
      if (!identical(changed, _changed) || !isActive) continue;
      return event;
    }
    return ControlKey(ControlCode.ctrlC);
  }

  void close() {
    if (closed) return;
    closed = true;
    _detach?.call();
    _hide?.call();
    if (!_changed.isCompleted) _changed.complete();
    owner._sessions.remove(this);
    owner._refresh();
  }
}
