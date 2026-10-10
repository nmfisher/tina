/// The two token estimators, side by side.
///
/// Both drive structural decisions, so both must stay honest about being
/// estimates — and both must stay VISIBLY different, because they measure
/// different inputs with different formulas on purpose:
///
/// - [estimateRequestTokensUtf8] is the context budget's gauge: UTF-8
///   bytes / 4, CEIL, over the FULL serialized provider-neutral request —
///   system prompt, every message (JSON-encoded, tool blocks included)
///   and the tool schemas. It decides whether the agent is nudged to edit
///   its working context, so over-reading is the safe direction.
/// - [estimateTranscriptTokensChars] is the compaction trigger:
///   characters / 4, FLOOR, over transcript text only — text blocks,
///   tool-result contents and reasoning, no JSON quoting, no tool
///   schemas. It decides when older history gets summarized, and the
///   threshold is configuration; the estimate only has to be honest
///   about order of magnitude.
///
/// The bytes/chars split is not accidental: a serialized request's byte
/// length is what the provider actually receives, while the transcript
/// gauge is a cheap pass over already-structured messages. Colocating
/// them is the point: a drift — same formula, same input — now shows up
/// as one diff in one file instead of two packages silently diverging.
/// No numbers changed in this extraction; any future unification is a
/// deliberate act with both call sites in view.
library;

import 'dart:convert';

import 'message.dart';

/// The context budget's default counter: UTF-8 bytes of the serialized
/// request divided by 4, rounded up. Embedders may substitute a real
/// tokenizer ([ContextTokenCounter] in tina_context); this default only
/// has to err on the visible side.
int estimateRequestTokensUtf8(String serializedRequest) =>
    (utf8.encode(serializedRequest).length / 4).ceil();

/// The compaction trigger's estimate: transcript characters — text
/// blocks, tool-result contents, reasoning — plus the system prompt,
/// divided by 4, rounded down. Deliberately crude: the threshold is
/// configuration, the estimate only has to be honest about order of
/// magnitude.
int estimateTranscriptTokensChars(String system, List<Message> messages) {
  var chars = system.length;
  for (final m in messages) {
    for (final b in m.content) {
      if (b is TextBlock) chars += b.text.length;
      if (b is ToolResultBlock) chars += b.content.length;
    }
    for (final r in m.reasoning) {
      chars += r.text.length;
    }
  }
  return chars ~/ 4;
}
