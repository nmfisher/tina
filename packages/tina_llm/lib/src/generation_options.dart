/// Explicit generation settings. Omitted reasoning settings preserve the
/// endpoint's defaults; each wire maps them to its own request vocabulary.
final class GenerationOptions {
  const GenerationOptions(
      {this.maxOutputTokens = 8192,
      this.reasoningEffort,
      this.thinkingBudget,
      this.webSearch = false,
      this.openAiOutputField = 'max_tokens'});
  final int maxOutputTokens;
  final String? reasoningEffort;
  final int? thinkingBudget;

  /// Server-side web search: the provider searches mid-generation and
  /// folds results into its answer. Only meaningful on wires that have a
  /// request field for it ([openAi] appends a `web_search` entry to
  /// `tools`; [anthropic] and [gemini] ignore it — their descriptors
  /// never set the capability).
  final bool webSearch;
  final String openAiOutputField;

  Map<String, dynamic> anthropic(Map<String, dynamic> body) => {
        ...body,
        'max_tokens': maxOutputTokens,
        if (reasoningEffort != null && reasoningEffort != 'none')
          'output_config': {'effort': reasoningEffort},
        if (thinkingBudget != null)
          'thinking': thinkingBudget == 0
              ? {'type': 'disabled'}
              : {'type': 'enabled', 'budget_tokens': thinkingBudget},
        if (thinkingBudget == null && reasoningEffort != null)
          'thinking': {
            'type': reasoningEffort == 'none' ? 'disabled' : 'adaptive'
          },
      };
  Map<String, dynamic> openAi(Map<String, dynamic> body) => {
        for (final entry in body.entries)
          if (entry.key != 'max_tokens') entry.key: entry.value,
        openAiOutputField: maxOutputTokens,
        if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
        // The server-side search rides `tools` beside the function tools
        // (GLM/z.ai shape): a non-function entry the server itself
        // answers, never a tool call the model sees. `tools` may be
        // absent — `chatCompletionsBody` emits it only when function
        // tools exist.
        if (webSearch)
          'tools': [
            ...?body['tools'] as List<dynamic>?,
            {
              'type': 'web_search',
              'web_search': {'enable': true},
            },
          ],
      };
  Map<String, dynamic> gemini(Map<String, dynamic> body) => {
        ...body,
        'generationConfig': {
          ...?body['generationConfig'] as Map<String, dynamic>?,
          'maxOutputTokens': maxOutputTokens,
          if (thinkingBudget != null || reasoningEffort != null)
            'thinkingConfig': {
              if (thinkingBudget != null) 'thinkingBudget': thinkingBudget,
              if (thinkingBudget == null && reasoningEffort != null)
                'thinkingLevel': reasoningEffort!.toUpperCase(),
            },
        },
      };
}
