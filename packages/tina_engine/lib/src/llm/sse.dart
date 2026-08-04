import 'dart:async';
import 'dart:convert';

/// Yield the JSON payload of each `data:` SSE line. The caller decodes it.
/// Stops when it sees `data: [DONE]`. Ignores `event:`, comments, blank lines.
Stream<String> parseSse(Stream<List<int>> input) async* {
  final lines = input.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final payload = line.substring(5).trimLeft();
    if (payload == '[DONE]') return;
    yield payload;
  }
}
