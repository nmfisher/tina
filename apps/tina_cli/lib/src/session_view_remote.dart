/// The remote front end's presentation: the view set built from the
/// connection (never from plugin instances — the wire carries ids, not
/// objects), approval asks as a decision dialog, and the settings entry as
/// an honest stub. See `tui_remote.dart` for the boundary.
library;

import 'dart:async';

import 'package:tina_approvals/tina_approvals.dart'
    show ApprovalDecision, ApprovalKind, ApprovalRequest;
import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart' show SessionPresentation, SessionSettingsView;

import 'console_catalog.dart' show connectionViewFor;
import 'pipes_connection.dart' show PipesApprovals, PipesConnection;

/// Builds the remote view set for one attachment lifecycle: the
/// connection-driven catalog entries for every plugin the engine lists,
/// plus the status strip. [listen] replays the current set and then diffs
/// snapshot updates, so `/plugins` reloads keep the attached views in sync.
final class RemotePluginViews {
  RemotePluginViews(this._connection) {
    _attachment = _connection.attach();
    unawaited(_observe());
  }

  final PipesConnection _connection;
  late final SessionAttachment _attachment;
  final _listeners =
      <Object, void Function(String, ConsoleContribution)>{};
  final _unlisteners = <Object, void Function(String)>{};
  final _replayed = <Object, Set<String>>{};
  List<String> _plugins = const [];
  bool _disposed = false;

  Map<String, ConsoleContribution> current() => _views(_plugins);

  /// The approval dialog rides the engine's stream approval channel —
  /// both the wasm baseline and the native `--pipes` engine list it as
  /// `tina/approvals-stream`. The status strip is pure layout and needs no
  /// plugin, so a remote front end always provides it.
  Map<String, ConsoleContribution> _views(List<String> plugins) {
    final result = <String, ConsoleContribution>{};
    final ids = <String>{
      ...plugins,
      'tina/status-strip-tui',
      'tina/approvals-stream',
    };
    for (final id in ids) {
      final view = id == 'tina/approvals-stream'
          ? PipesApprovalView(_connection.approvals)
          : connectionViewFor(id, _connection);
      if (view != null) result[id] = view;
    }
    return result;
  }

  void Function() listen(
      void Function(String, ConsoleContribution) loaded,
      void Function(String) unloading) {
    final key = Object();
    _listeners[key] = loaded;
    _unlisteners[key] = unloading;
    final replayed = {..._views(_plugins)};
    _replayed[key] = replayed.keys.toSet();
    for (final entry in replayed.entries) {
      loaded(entry.key, entry.value);
    }
    return () {
      _listeners.remove(key);
      _unlisteners.remove(key);
      _replayed.remove(key);
    };
  }

  Future<void> _observe() async {
    var snapshot = _attachment.initial;
    while (!_disposed) {
      _apply(snapshot);
      final update = await _attachment.next();
      if (update == null || _disposed) return;
      snapshot = update.snapshot;
    }
  }

  void _apply(SessionSnapshot snapshot) {
    final plugins = snapshot.plugins;
    if (plugins.length == _plugins.length &&
        plugins.every(_plugins.contains)) {
      return;
    }
    _plugins = plugins;
    for (final key in _listeners.keys.toList()) {
      final replayed = _replayed[key];
      if (replayed == null) continue;
      // Iterate copies: the callbacks below mutate the sets.
      for (final id in replayed.where((id) => !plugins.contains(id)).toList()) {
        replayed.remove(id);
        try {
          _unlisteners[key]?.call(id);
        } catch (_) {/* A stale view must not block the next update. */}
      }
      for (final id in plugins.where((id) => !replayed.contains(id)).toList()) {
        final view = connectionViewFor(id, _connection);
        if (view == null) continue;
        replayed.add(id);
        try {
          _listeners[key]!(id, view);
        } catch (_) {
          replayed.remove(id);
        }
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    _unlisteners.clear();
    _replayed.clear();
    _attachment.close();
  }
}

/// Presentation for the remote front end: constant default theme (the wire
/// carries no theme), no config note, view creation through
/// [RemotePluginViews], and a settings entry that says what is true.
SessionPresentation presentationForRemote(PipesConnection connection) {
  final views = RemotePluginViews(connection);
  return SessionPresentation(
      theme: () => const Theme.defaults(),
      configNote: null,
      quitRequested: () => false,
      createViews: views.current,
      listenViews: views.listen,
      listenTheme: (listener) => () {},
      settingsFor: (context) => SessionSettingsView(
          open: () async =>
              'The remote engine serves settings discovery only. Edit the '
              'config file and restart to apply.',
          repaint: () {},
          close: () {}));
}

/// Decision dialog for the engine's approval asks: `y` allow once, `a`
/// allow always (permission asks only), `n` or Esc deny. Escape denies —
/// a closed dialog never leaves the turn hanging on an unrendered ask.
final class PipesApprovalView implements ConsoleContribution {
  PipesApprovalView(this.approvals);
  final PipesApprovals approvals;
  ConsoleContext? _context;
  void Function()? _unlisten;
  final _pending = <String, _ApprovalDraft>{};
  void Function()? _paint;

  @override
  void attachConsole(ConsoleContext context) {
    if (_context != null) throw StateError('approval view already attached');
    _context = context;
    _unlisten = approvals.listen((requests) {
      final ids = requests.map((request) => request.id).toSet();
      for (final entry in _pending.entries.toList()) {
        if (!ids.contains(entry.key)) {
          entry.value.close();
          _pending.remove(entry.key);
        }
      }
      for (final request in requests) {
        if (_pending.containsKey(request.id)) continue;
        final draft = _ApprovalDraft(request);
        _pending[request.id] = draft;
        unawaited(_present(context, draft));
      }
    });
  }

  bool _active(ConsoleContext context, _ApprovalDraft draft) =>
      identical(_context, context) &&
      !draft.closed.isCompleted &&
      approvals.pending.any((request) => request.id == draft.request.id);

  Future<void> _present(ConsoleContext context, _ApprovalDraft draft) async {
    try {
      await context.interactIf(() => _active(context, draft), () async {
        final input = context.openInputSession(
            globalKeys: true,
            panelNavigation: false,
            acceptPaste: false,
            releaseOnEscape: true,
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
        var top = 0, page = 1;
        void paint() {
          final screen = context.screen;
          final bounds = dialogBounds(screen.layout,
              preferredWidth: 78, preferredHeight: 12);
          final framed = bounds.width >= 4 && bounds.height >= 6;
          final width = (bounds.width - (framed ? 4 : 0)).clamp(0, 78);
          page = (bounds.height - (framed ? 5 : 1)).clamp(0, 12);
          final rows = wrapDialogWords(_plainDialog(_body(draft.request)), width);
          top = top.clamp(0, (rows.length - page).clamp(0, rows.length));
          final prompt = rows.skip(top).take(page).toList();
          final footer = draft.request.kind == ApprovalKind.permission
              ? 'y allow once · a allow always · n/Esc deny'
              : 'y allow · n/Esc deny';
          final lines = framed
              ? dialogBoxLines(
                  width: bounds.width,
                  height: bounds.height,
                  title: 'Approval request',
                  body: prompt,
                  footer: footer,
                  paint: (text) =>
                      screen.colorize(screen.theme.border.focus, text))
              : [...prompt, footer].take(bounds.height).toList();
          screen.frame(() {
            overlay.update(bounds: bounds, lines: lines);
            if (bounds.height > 0 && width > 0) {
              cursor.place(bounds.row + (framed ? 1 : 0) + prompt.length,
                  bounds.col + (framed ? 2 : 0));
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
            final respond = (ApprovalDecision decision) {
              approvals.respond(draft.request.id, decision);
            };
            switch (event) {
              case EscapeKey():
                respond(ApprovalDecision.deny);
              case ControlKey(code: ControlCode.ctrlC):
                // Global quit or disposed input detaches; never answers.
                return;
              case ControlKey(code: ControlCode.enter):
                respond(ApprovalDecision.allow);
              case CharInput(:final text) when text == 'y' || text == 'Y':
                respond(ApprovalDecision.allow);
              case CharInput(:final text)
                  when text == 'a' || text == 'A':
                respond(draft.request.kind == ApprovalKind.permission
                    ? ApprovalDecision.allowAlways
                    : ApprovalDecision.allow);
              case CharInput(:final text) when text == 'n' || text == 'N':
                respond(ApprovalDecision.deny);
              case ArrowKey(direction: ArrowDirection.pageUp):
                top = (top - page).clamp(0, top);
              case ArrowKey(direction: ArrowDirection.pageDown):
                top += page;
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
      // A failed presenter has no authority to answer a shared ask.
    } finally {
      if (identical(_pending[draft.request.id], draft)) {
        _pending.remove(draft.request.id);
      }
    }
  }

  String _body(ApprovalRequest request) {
    final buffer = StringBuffer('${request.operation} ${request.target}');
    if (request.reason.isNotEmpty) buffer.write('\n${request.reason}');
    return buffer.toString();
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

final class _ApprovalDraft {
  _ApprovalDraft(this.request);
  final ApprovalRequest request;
  final closed = Completer<void>();
  void Function()? dispose;
  void close() {
    if (!closed.isCompleted) closed.complete();
    dispose?.call();
  }
}

String _plainDialog(String value) =>
    value.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
