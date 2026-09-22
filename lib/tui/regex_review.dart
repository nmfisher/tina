import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// Local form state. The approval's existing PromptSession retains focus,
/// cancellation and suspension; this never mutates the conversation draft.
class RegexReview {
  final PermissionPrompt prompt;

  /// The model that drafts a general-but-safe pattern, or null when no
  /// classifier/provider is wired and only the literal escape is available.
  final RegexSuggester? suggester;
  late TextLineInput input;
  PermissionRule? rule;
  String? error;
  int selected = 0;
  bool get reviewing => rule != null;
  static const actions = [
    'Allow and save for this conversation',
    'Edit regex',
    'Back to approval',
  ];

  /// Set while the model draft is in flight, cleared when it settles.
  bool suggestionPending = false;

  /// One-line status of the model draft: what arrived, or why nothing did.
  String? status;

  /// Whether the suggester's pattern (as opposed to the user's own edit) is
  /// what the buffer currently holds.
  bool get showingSuggestion => _suggestionArrived && !_userEdited;
  bool _suggestionArrived = false;
  bool _userEdited = false;

  /// Set once the review has handed control back to the approval loop — a
  /// draft that lands afterwards is dropped instead of repainting a dead form.
  bool _settled = false;

  /// Called when the async suggestion settles so the approval loop repaints.
  void Function()? onChanged;

  RegexReview(this.prompt, {this.suggester}) {
    // The literal escape paints immediately: the form is usable before the
    // model answers, and is the fallback when the draft fails or is refused.
    final suggestion = prompt.suggestedRegex;
    input = TextLineInput(buffer: suggestion, cursor: suggestion.length);
    _startSuggestion();
  }

  void _startSuggestion() {
    final suggester = this.suggester;
    if (suggester == null) return;
    suggestionPending = true;
    status = 'asking the model to generalize the pattern…';
    suggester.suggest(prompt).then((draft) {
      if (_settled) return;
      _applySuggestion(draft);
      onChanged?.call();
    });
  }

  void _applySuggestion(RegexSuggestion draft) {
    suggestionPending = false;
    if (!draft.isSuccess) {
      status =
          'model draft unavailable (${draft.failure!.phrase(timeout: suggester!.timeout)}) — literal pattern kept';
      return;
    }
    // Too late to swap the buffer: the user already typed, confirmed a rule,
    // or left. Their text (or their confirmed rule) wins over a late draft.
    if (_userEdited || reviewing) {
      status = 'model draft arrived late — your edit was kept';
      return;
    }
    final pattern = draft.rule!.pattern;
    input = TextLineInput(buffer: pattern, cursor: pattern.length);
    _suggestionArrived = true;
    status = 'model-drafted pattern — check what it allows before allowing';
  }

  /// Marks the form dead so a still-running draft cannot repaint it.
  void abandon() {
    _settled = true;
    onChanged = null;
  }

  List<String> get lines => [
    'Tool: ${prompt.toolName}',
    'Target: ${prompt.key}',
    '',
    'Regex: ${input.buffer}',
    'Matches the entire approval target.',
    'Scope: this conversation, until tina exits.',
    if (!reviewing) ...[
      if (status != null) status!,
      if (status == null && suggester == null)
        'The suggestion matches only this target. Edit to change what is allowed.',
    ],
    if (reviewing) 'Allow this call and future matching calls?',
    if (error != null) error!,
  ];

  PermissionResponse get response => PermissionResponse(
    PermissionDecision.allow,
    remember: true,
    scope: GrantScope.conversation,
    rule: rule!,
  );

  RegexReviewResult handle(InputEvent event) {
    if (event is EscapeKey) {
      if (!reviewing) {
        abandon();
        return RegexReviewResult.back;
      }
      rule = null;
      return RegexReviewResult.pending;
    }
    if (reviewing) {
      if (event is ArrowKey) {
        if (event.direction == ArrowDirection.up)
          selected = (selected - 1).clamp(0, 2);
        if (event.direction == ArrowDirection.down)
          selected = (selected + 1).clamp(0, 2);
      } else if (event is ControlKey && event.code == ControlCode.enter) {
        if (selected == 0) {
          abandon();
          return RegexReviewResult.approved;
        }
        if (selected == 2) {
          abandon();
          return RegexReviewResult.back;
        }
        rule = null;
      }
      return RegexReviewResult.pending;
    }
    if (event is ControlKey && event.code == ControlCode.enter) {
      try {
        rule = prompt.regexRule(input.buffer);
        error = null;
        selected = 0;
      } on FormatException catch (e) {
        error = e.message;
      }
      return RegexReviewResult.pending;
    }
    final text = switch (event) {
      CharInput(:final text) || PasteInput(:final text) => text,
      _ => null,
    };
    if (text != null) {
      // Keep terminal controls out of the input row; escaped regex forms work.
      if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
        error = r'Use escaped control characters such as \n or \t.';
      } else {
        input = input.insert(text);
        error = null;
        _userEdited = true;
      }
    } else if (event is ControlKey && event.code == ControlCode.backspace) {
      input = input.backspace();
      _userEdited = true;
    } else if (event is ArrowKey) {
      input = switch (event.direction) {
        ArrowDirection.left =>
          event.hasCtrl || event.hasAlt
              ? input.moveWordLeft()
              : input.moveLeft(),
        ArrowDirection.right =>
          event.hasCtrl || event.hasAlt
              ? input.moveWordRight()
              : input.moveRight(),
        _ => input,
      };
    } else if (event is EditingKey) {
      final before = input.buffer;
      input = switch (event.action) {
        EditingAction.home => input.moveHome(),
        EditingAction.end => input.moveEnd(),
        EditingAction.delete => input.deleteForward(),
        EditingAction.killToEnd => input.killToEnd(),
        EditingAction.killToStart => input.killToStart(),
        EditingAction.deleteWordBackward => input.killWordBackward(),
        EditingAction.deleteWordForward => input.killWordForward(),
      };
      if (input.buffer != before) _userEdited = true;
    }
    return RegexReviewResult.pending;
  }
}

enum RegexReviewResult { pending, back, approved }
