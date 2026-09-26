/// Shared value types and the model-provider interface, copied from
/// `tina_engine` (`lib/src/llm/message.dart`, `lib/src/llm/provider.dart`,
/// `lib/src/tools/tool.dart`) so a provider package and a loop package can
/// both depend on this without depending on each other.
///
/// First copy for review; removing the originals from `tina_engine` is a
/// later step. This package depends on nothing — standard library only.
library;

export 'src/message.dart';
export 'src/provider.dart';
export 'src/stream.dart';
export 'src/tools.dart';
