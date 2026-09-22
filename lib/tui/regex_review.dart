import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// Local form state. The approval's existing PromptSession retains focus,
/// cancellation and suspension; this never mutates the conversation draft.
class RegexReview {
  final PermissionPrompt prompt;
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

  RegexReview(this.prompt) {
    final suggestion = prompt.suggestedRegex;
    input = TextLineInput(buffer: suggestion, cursor: suggestion.length);
  }

  List<String> get lines => [
    'Tool: ${prompt.toolName}',
    'Target: ${prompt.key}',
    '',
    'Regex: ${input.buffer}',
    'Matches the entire approval target.',
    'Scope: this conversation, until tina exits.',
    if (!reviewing)
      'The suggestion matches only this target. Edit to change what is allowed.',
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
      if (!reviewing) return RegexReviewResult.back;
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
        if (selected == 0) return RegexReviewResult.approved;
        if (selected == 2) return RegexReviewResult.back;
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
      }
    } else if (event is ControlKey && event.code == ControlCode.backspace) {
      input = input.backspace();
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
    return RegexReviewResult.pending;
  }
}

enum RegexReviewResult { pending, back, approved }
