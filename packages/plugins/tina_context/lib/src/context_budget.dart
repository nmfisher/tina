import 'dart:convert';

import 'package:tina_engine_2/tina_engine_2.dart';

export 'package:tina_core/tina_core.dart'
    show estimateRequestTokensUtf8;

/// Counts the provider-neutral serialized request. Embedders may substitute a
/// tokenizer; the default is an explicitly approximate UTF-8 bytes / 4 gauge.
typedef ContextTokenCounter = int Function(String serializedRequest);

final estimateContextTokens = estimateRequestTokensUtf8;

String serializeContextRequest(TurnContext context) => jsonEncode({
      'system': context.promptSections.where((s) => s.isNotEmpty).join('\n\n'),
      'messages': [for (final message in context.messages) message.toJson()],
      'tools': [
        for (final tool in context.pinnedTools)
          {
            'name': tool.name,
            'description': tool.description,
            'input_schema': tool.inputSchema,
          },
      ],
    });

final class ContextBudgetUsage {
  const ContextBudgetUsage({
    required this.inputTokens,
    required this.budgetTokens,
    required this.responseReserveTokens,
    required this.reminder,
  });
  final int inputTokens, budgetTokens, responseReserveTokens;
  final String? reminder;
  int get inputLimit => budgetTokens - responseReserveTokens;

  /// Signed: a negative value means the estimated request exceeds its allowance.
  int get remainingInputTokens => inputLimit - inputTokens;
  double get fractionUsed => inputTokens / budgetTokens;
}

/// Reminders are ephemeral request instructions, never conversation entries.
/// A downward crossing rearms reminders after the agent reduces its context.
final class ContextBudget {
  ContextBudget({ContextTokenCounter? counter})
      : counter = counter ?? estimateContextTokens;
  final ContextTokenCounter counter;
  ContextBudgetUsage? latestUsage;
  int _band = 0;
  int? _budget, _reserve;

  int count(String serialized) {
    final value = counter(serialized);
    if (value < 0) throw StateError('Negative context token count');
    return value;
  }

  int countMessages(List<Message> messages) =>
      count(jsonEncode([for (final message in messages) message.toJson()]));

  void prepare(TurnContext context,
      {required int budget, required int reserve}) {
    if (budget < 1 || reserve < 0 || reserve >= budget) {
      throw const FormatException(
          'Response reserve must be non-negative and smaller than the context budget.');
    }
    if (_budget != budget || _reserve != reserve) _band = 0;
    _budget = budget;
    _reserve = reserve;
    final gaugeIndex = context.promptSections.length;
    context.promptSections.add('');
    int updateGauge() {
      var tokens = count(serializeContextRequest(context));
      // Including the gauge can change the count's digit width. Bounded
      // refinement avoids recursive request construction or unbounded work.
      for (var i = 0; i < 4; i++) {
        context.promptSections[gaugeIndex] =
            'Working context budget: estimated input ~$tokens / $budget tokens; '
            '$reserve tokens reserved for the response; '
            '~${budget - reserve - tokens} input tokens remaining. '
            'This gauge estimates the full serialized request, including tools.';
        final next = count(serializeContextRequest(context));
        if (next == tokens) break;
        tokens = next;
      }
      return count(serializeContextRequest(context));
    }

    final input = updateGauge();
    int bandFor(int input) => input * 100 >= budget * 75
        ? 75
        : input * 100 >= budget * 50
            ? 50
            : input * 100 >= budget * 25
                ? 25
                : 0;
    final band = bandFor(input);
    const urgentText =
        'Context budget URGENT: the estimated request has exhausted the input allowance. '
        'Reduce working context before continuing; preserve the current task and useful evidence.';
    String? reminder;
    if (input + reserve >= budget || band > _band) {
      reminder = input + reserve >= budget
          ? urgentText
          : 'Context budget reminder: estimated input has crossed $band% of the $budget-token budget. '
              'Choose whether to remove, summarize, or offload information you no longer need.';
      context.promptSections.add(reminder);
    }
    var finalInput = updateGauge();
    if (finalInput + reserve >= budget && reminder != urgentText) {
      if (reminder == null) {
        context.promptSections.add(urgentText);
      } else {
        context.promptSections[context.promptSections.length - 1] = urgentText;
      }
      reminder = urgentText;
      finalInput = updateGauge();
    }
    _band = bandFor(finalInput);
    latestUsage = ContextBudgetUsage(
        inputTokens: finalInput,
        budgetTokens: budget,
        responseReserveTokens: reserve,
        reminder: reminder);
  }

  void reset() {
    latestUsage = null;
    _band = 0;
    _budget = _reserve = null;
  }
}
