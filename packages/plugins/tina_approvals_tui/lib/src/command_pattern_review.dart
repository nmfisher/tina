import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_console/tina_console.dart';
import 'approval_dialog.dart';

typedef CommandPatternSuggestion = ({
  String? pattern,
  String? explanation,
  String? failure
});
typedef SuggestCommandPattern = Future<CommandPatternSuggestion> Function(
    ApprovalRequest request, Future<void> whenCancelled);

/// Raw events are needed only while the user edits a command approval rule.
abstract interface class CommandPatternKeySource implements KeySource {
  Future<InputEvent?> nextEvent();
  void editingPattern(bool editing);
}

enum CommandPatternReviewResult { pending, back, approved, denied }

final class CommandPatternReview {
  CommandPatternReview(this.request,
      {SuggestCommandPattern? suggest, this.onChange}) {
    final literal = CommandApprovalPattern.escape(target);
    input = TextLineInput(buffer: literal, cursor: literal.length);
    if (suggest == null) {
      status = 'Model suggestion unavailable; edit the literal pattern.';
    } else {
      status = 'Asking the model to suggest a flexible regex…';
      unawaited(
          Future.sync(() => suggest(request, _cancel.future)).then((draft) {
        if (_closed) return;
        if (_edited || reviewing) {
          status = 'Your edit was kept; the model suggestion arrived later.';
        } else {
          try {
            if (draft.pattern == null) {
              throw FormatException(draft.failure ?? 'no suggestion');
            }
            CommandApprovalPattern(draft.pattern!).requireMatch(target);
            input = TextLineInput(
                buffer: draft.pattern!, cursor: draft.pattern!.length);
            status =
                'Model suggestion: ${draft.explanation ?? 'Review what this allows.'}';
          } on FormatException {
            status =
                'Model suggestion unavailable (${draft.failure ?? 'invalid suggestion'}); literal pattern kept.';
          }
        }
        onChange?.call();
      }, onError: (Object _) {
        if (_closed) return;
        status = 'Model suggestion unavailable; your pattern was kept.';
        onChange?.call();
      }));
    }
  }

  final ApprovalRequest request;
  String get target => request.details['command_pattern_target'] as String;
  late TextLineInput input;
  String? status, error;
  bool reviewing = false;
  bool _edited = false, _closed = false;
  final _cancel = Completer<void>();
  void Function()? onChange;
  int selected = 0, _offset = 0, _maxOffset = 0, _pageSize = 1;
  (int, int)? cursor;
  bool get _persistent => request.details['persistent_command_pattern'] == true;
  List<ApprovalDecision> get _scopes => [
        ApprovalDecision.allowAlways,
        if (_persistent) ...[
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal
        ],
      ];
  List<String> get _actions => [
        'Allow and save for this session',
        if (_persistent) ...[
          'Allow and save for this workspace',
          'Allow and save globally (any directory)'
        ],
        'Edit regex',
        'Back to approval',
      ];
  ApprovalOutcome get outcome =>
      ApprovalOutcome(_scopes[selected], commandPattern: input.buffer);

  void close() {
    if (_closed) return;
    _closed = true;
    onChange = null;
    _cancel.complete();
  }

  CommandPatternReviewResult handle(InputEvent event) {
    if (event is ControlKey && event.code == ControlCode.ctrlC) {
      return CommandPatternReviewResult.denied;
    }
    if (event is EscapeKey) {
      if (!reviewing) return CommandPatternReviewResult.back;
      reviewing = false;
      _offset = 0;
      return CommandPatternReviewResult.pending;
    }
    if (event is ArrowKey &&
        {ArrowDirection.pageUp, ArrowDirection.pageDown}
            .contains(event.direction)) {
      _offset = (_offset +
              (event.direction == ArrowDirection.pageUp
                  ? -_pageSize
                  : _pageSize))
          .clamp(0, _maxOffset);
      return CommandPatternReviewResult.pending;
    }
    if (event is ScrollEvent) {
      _offset = (_offset + (event.up ? -3 : 3)).clamp(0, _maxOffset);
      return CommandPatternReviewResult.pending;
    }
    if (reviewing) {
      if (event is ArrowKey) {
        if (event.direction == ArrowDirection.up)
          selected = (selected - 1).clamp(0, _actions.length - 1);
        if (event.direction == ArrowDirection.down)
          selected = (selected + 1).clamp(0, _actions.length - 1);
      } else if (event is ControlKey && event.code == ControlCode.enter) {
        if (selected < _scopes.length)
          return CommandPatternReviewResult.approved;
        if (selected == _actions.length - 1)
          return CommandPatternReviewResult.back;
        reviewing = false;
      }
      return CommandPatternReviewResult.pending;
    }
    if (event is ControlKey && event.code == ControlCode.enter) {
      try {
        CommandApprovalPattern(input.buffer).requireMatch(target);
        error = null;
        reviewing = true;
        selected = _offset = 0;
      } on FormatException catch (e) {
        error = e.message;
      }
      return CommandPatternReviewResult.pending;
    }
    final before = input.buffer;
    final text = switch (event) {
      CharInput(:final text) || PasteInput(:final text) => text,
      _ => null,
    };
    if (text != null) {
      if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text)) {
        error = r'Use escaped controls such as \n or \t.';
        return CommandPatternReviewResult.pending;
      }
      if (input.buffer.length + text.length > 2048) {
        error = 'Regex must be at most 2048 characters.';
        return CommandPatternReviewResult.pending;
      }
      input = input.insert(text);
    } else if (event is ControlKey && event.code == ControlCode.backspace) {
      input = input.backspace();
    } else if (event is ArrowKey) {
      input = switch (event.direction) {
        ArrowDirection.left => event.hasCtrl || event.hasAlt
            ? input.moveWordLeft()
            : input.moveLeft(),
        ArrowDirection.right => event.hasCtrl || event.hasAlt
            ? input.moveWordRight()
            : input.moveRight(),
        _ => input,
      };
    } else if (event is EditingKey) {
      input = switch (event.action) {
        EditingAction.home => input.moveHome(),
        EditingAction.end => input.moveEnd(),
        EditingAction.delete => input.deleteForward(),
        EditingAction.killToEnd => input.killToEnd(),
        EditingAction.killToStart => input.killToStart(),
        EditingAction.deleteWordBackward => input.killWordBackward(),
        EditingAction.deleteWordForward => input.killWordForward(),
      };
    }
    if (before != input.buffer) {
      _edited = true;
      error = null;
    }
    return CommandPatternReviewResult.pending;
  }

  List<RenderLine> rows(
      {required int width, required int height, required Theme theme}) {
    cursor = null;
    if (width < 1 || height < 1) return [];
    RenderLine row(String text, [String? color]) =>
        RenderLine(runs: [RenderRun(clipDialogText(text, width), color)]);
    String safe(String value) => value.replaceAllMapped(
        RegExp(r'[\x00-\x1f\x7f-\x9f]'),
        (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}');
    final permissions = request.details['required_permissions'];
    final outside = permissions is List && permissions.contains('unconfined');
    final network = permissions is List && permissions.contains('network');
    final context = [
      'Command: $target',
      if (reviewing) 'Regex: ${input.buffer}',
      'Matches the entire command. Keep patterns narrow around values that may vary.',
      'Executable, environment, input and granted permissions stay fixed.',
      outside
          ? 'Access: outside sandbox, host filesystem, real HOME credentials and network.'
          : network
              ? 'Access: sandboxed execution with network access.'
              : 'Access: sandboxed execution.',
      if (request.details['cwd'] != null)
        'Directory: ${request.details['cwd']}',
      'Session/workspace rules keep this directory; global rules apply in any directory.',
    ];
    final wrapped = [
      for (final text in context)
        for (final line in wrapDialogText(safe(text), width))
          row(line, theme.chat.dim)
    ];
    final choices = reviewing
        ? [
            for (var i = 0; i < _actions.length; i++)
              row('${i == selected ? '❯' : ' '} ${_actions[i]}',
                  i == selected ? theme.dialog.confirm : null)
          ]
        : <RenderLine>[];
    final actions = reviewing
        ? height >= choices.length + 4
            ? choices
            : [choices[selected]]
        : <RenderLine>[];
    final footer = reviewing
        ? '↑↓ choose · Enter save · Esc edit · PgUp/PgDn context'
        : 'Enter review · Esc back · PgUp/PgDn context';
    final note = error == null ? status : 'Error: $error';
    final available =
        (height - actions.length - (reviewing ? 2 : 3) - (note == null ? 0 : 1))
            .clamp(0, wrapped.length);
    _pageSize = available.clamp(1, wrapped.length.clamp(1, 100000));
    _maxOffset = (wrapped.length - available).clamp(0, wrapped.length);
    _offset = _offset.clamp(0, _maxOffset);
    final view = textFieldView(input, width: (width - 7).clamp(1, width));
    final lines = [
      row(
          reviewing
              ? 'Review always-approve regex'
              : 'Edit always-approve regex',
          theme.dialog.confirm),
      ...wrapped.skip(_offset).take(available),
      if (note != null)
        row(safe(note), error == null ? theme.chat.dim : theme.chat.red),
      row(footer, theme.chat.dim),
      ...actions,
      if (!reviewing) row('Regex: ${view.text}', theme.dialog.confirm),
    ];
    // The editable field / selected action must survive a very short terminal.
    final visible =
        lines.skip((lines.length - height).clamp(0, lines.length)).toList();
    if (!reviewing)
      cursor =
          (visible.length - 1, (7 + view.cursorColumn).clamp(0, width - 1));
    return visible;
  }
}
