/// CSV export of event streams.
library;

import 'package:core/core.dart';

/// Serializes [events] to CSV with a header row.
///
/// Fields containing commas, quotes, or newlines are quoted and escaped
/// per RFC 4180.
String exportCsv(List<TaskEvent> events) {
  final rows = [
    'task_id,timestamp,type,title',
    ...events.map((e) {
      final title = switch (e) {
        TaskCreated(:final title) => title,
        TaskRenamed(:final title) => title,
        _ => '',
      };
      return [
        _field(e.taskId),
        _field(e.at.toString()),
        _field(e.type),
        _field(title),
      ].join(',');
    }),
  ];
  return '${rows.join('\n')}\n';
}

String _field(String raw) =>
    raw.contains(RegExp('[",\n]')) ? '"${raw.replaceAll('"', '""')}"' : raw;
