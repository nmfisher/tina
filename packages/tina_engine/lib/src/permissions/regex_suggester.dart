import 'dart:async';
import 'dart:convert';

import '../llm/message.dart';
import '../llm/provider.dart';
import 'policy.dart';
import 'prompt.dart';

/// Why no model-drafted pattern is available for the regex review.
enum RegexSuggestionFailure {
  /// No answer arrived within [RegexSuggester.timeout].
  timeout,

  /// The provider stream failed (network, HTTP, provider error).
  streamError,

  /// The stream completed with a pattern that is not a valid regular
  /// expression, does not match the approval target, or contains control
  /// characters the review row cannot show.
  invalid,

  /// The turn was cancelled while the draft was being requested.
  cancelled;

  /// The dim status line the review shows while the user waits or when the
  /// draft failed — same voice as [ClassifierFailure.phrase].
  String phrase({required Duration timeout}) => switch (this) {
        RegexSuggestionFailure.timeout =>
          'timed out after ${timeout.inSeconds >= 1 ? '${timeout.inSeconds}s' : '${timeout.inMilliseconds}ms'}',
        RegexSuggestionFailure.streamError => 'provider error',
        RegexSuggestionFailure.invalid => 'unusable answer',
        RegexSuggestionFailure.cancelled => 'cancelled',
      };
}

/// The outcome of one suggestion request.
class RegexSuggestion {
  final PermissionRule? rule;
  final RegexSuggestionFailure? failure;

  const RegexSuggestion.allow(this.rule)
      : failure = null,
        assert(rule != null);
  const RegexSuggestion.failed(this.failure)
      : rule = null,
        assert(failure != null);

  bool get isSuccess => rule != null;
}

/// Drafts a "general but safe" allow rule for one approval with an LLM call.
///
/// This is the other half of the `[r] rewrite to safe regular expression`
/// choice: [PermissionPrompt.suggestedRegex] only escapes the exact target,
/// which is no more general than the `[a] allow always` answer. The suggester
/// asks a model to generalize — same tool, broader pattern — and validates the
/// draft mechanically before the user sees it:
///
/// 1. It must be a valid Dart regular expression.
/// 2. It must match the approval target being decided (a rule for a call the
///    user is not looking at would be a lie on the confirmation row).
/// 3. It must not contain raw control characters (the review edits one line).
///
/// Every failure mode lands in [RegexSuggestion.failure] — never a throw —
/// so the review can fall back to the literal escape and say why.
class RegexSuggester {
  final LlmProvider provider;
  final Duration timeout;

  /// One generalization request per approval; there is no retry loop. The
  /// user can edit the pattern by hand regardless of the outcome.
  RegexSuggester(this.provider, {this.timeout = const Duration(seconds: 20)});

  Future<RegexSuggestion> suggest(PermissionPrompt prompt) async {
    var cancelled = false;
    try {
      final stream = provider.send(
        system: _systemPrompt,
        messages: [
          Message(role: Role.user, content: [
            TextBlock(jsonEncode({
              'tool': prompt.toolName,
              'target': prompt.key,
            })),
          ]),
        ],
        tools: const [],
      );

      final buf = StringBuffer();
      final done = Completer<void>();
      Object? err;
      final sub = stream.listen(
        (event) {
          if (event is TextDelta) {
            buf.write(event.text);
          } else if (event is StreamError) {
            err = event.error;
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          err = e;
          if (!done.isCompleted) done.complete();
        },
      );
      var timedOut = false;
      try {
        await Future.any<void>([
          done.future,
          if (prompt.cancelSignal != null)
            prompt.cancelSignal!.then((_) => cancelled = true),
        ]).timeout(timeout);
      } on TimeoutException {
        timedOut = true;
      } finally {
        await sub.cancel();
      }

      if (cancelled) {
        return const RegexSuggestion.failed(RegexSuggestionFailure.cancelled);
      }
      if (timedOut) {
        return const RegexSuggestion.failed(RegexSuggestionFailure.timeout);
      }
      if (err != null) {
        return const RegexSuggestion.failed(RegexSuggestionFailure.streamError);
      }
      return _validated(buf.toString().trim(), prompt);
    } catch (_) {
      return const RegexSuggestion.failed(RegexSuggestionFailure.streamError);
    }
  }

  /// Shared validation for drafted patterns. Kept off the instance so the
  /// tests can pin the acceptance contract without a provider.
  static RegexSuggestion _validated(String pattern, PermissionPrompt prompt) {
    if (pattern.isEmpty || pattern.length > 500) {
      return const RegexSuggestion.failed(RegexSuggestionFailure.invalid);
    }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(pattern)) {
      return const RegexSuggestion.failed(RegexSuggestionFailure.invalid);
    }
    try {
      final rule = prompt.regexRule(pattern);
      return RegexSuggestion.allow(rule);
    } on FormatException {
      return const RegexSuggestion.failed(RegexSuggestionFailure.invalid);
    } catch (_) {
      // RegExp may throw FormatException subclasses or other errors on
      // malformed patterns; they all mean "unusable draft".
      return const RegexSuggestion.failed(RegexSuggestionFailure.invalid);
    }
  }
}

const _systemPrompt = '''
You write allowlist regular expressions for an agent's permission system.

You are given a tool name and the exact approval target (the string a rule
must match) for ONE tool call the user is about to approve. Write a Dart
regular expression that matches this target and the narrow family of calls
around it that are clearly as safe as this one.

Rules:
- Answer with ONLY the regular expression. No explanation, no code fence,
  no anchoring syntax beyond the pattern itself (the ^ start and the
  end-of-input assertion are supplied by the permission engine).
- Generalize conservatively. Prefer enumerating alternatives over wildcards:
  `git (status|diff|log)` rather than `git .*`.
- NEVER allow through anything more dangerous than the target: no extra
  subcommands with side effects, no additional executables, no path escapes
  outside the directories the target touches, no shell operators (`;`, `&&`,
  `|`, backticks, \$(...)`) unless the target itself contains them.
- If part of the target is a specific value (a branch name, a file name), you
  may generalize it to a character class only when any value in that position
  is equally safe. Keep everything else literal.
- The whole target must be covered: the engine tests the pattern against the
  entire target string, and the draft is rejected if it does not match.

Example — target `git status --porcelain` for tool `bash`:
git (status|diff|log)( --porcelain)?
''';
