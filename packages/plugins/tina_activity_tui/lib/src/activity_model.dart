import 'dart:convert';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Strip terminal controls before interpreting or displaying untrusted output.
String plainText(String text) => text
    .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '')
    .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');
String bounded(String text, [int limit = 65536]) => text.length <= limit
    ? text
    : '${text.substring(0, limit)}\n[details truncated]';

final class ActivityRecord {
  ActivityRecord(this.call, {bool historical = false, this.description})
      : state = historical ? 'recorded' : 'waiting';
  final ToolUse call;
  final ToolDescription? description;
  String get label => description?.title ?? plainText(call.name);
  String state;
  String output = '';
  String progress = '';
  final progressHistory = <String>[];
  ToolResult? result;
  DateTime? started;
  Duration? elapsed;
  bool expanded = false;
  bool truncated = false;
  bool get finished => result != null;
  String get duration => elapsed != null
      ? '${elapsed!.inMilliseconds} ms'
      : started != null
          ? '${DateTime.now().difference(started!).inSeconds}s'
          : '';
  String get target {
    if (description != null) return plainText(description!.target);
    final input = call.input;
    for (final key in ['filePath', 'path', 'command', 'prompt']) {
      if (input[key] is String)
        return plainText(input[key] as String).split('\n').first;
    }
    return '';
  }

  void append(String text) {
    final available = 65536 - output.length;
    if (available <= 0) {
      truncated = true;
      return;
    }
    final clean = plainText(text);
    output += clean.length <= available ? clean : clean.substring(0, available);
    if (clean.length > available) truncated = true;
  }

  void finish(ToolResult value) {
    if (finished) return;
    result = ToolResult(bounded(plainText(value.content)),
        isError: value.isError,
        elapsed: value.elapsed,
        timedOut: value.timedOut,
        emptyOutput: value.emptyOutput);
    elapsed = value.elapsed ??
        (started == null ? null : DateTime.now().difference(started!));
    state = value.timedOut == true
        ? 'timed out'
        : value.isError && value.content.contains('cancelled:')
            ? 'cancelled'
            : value.isError
                ? 'error'
                : 'done';
  }

  String get summary {
    final value = result;
    if (value == null) return progress.isEmpty ? state : progress;
    final object = _object(value.content);
    final message = object?['message'] ?? object?['error'];
    if (message is String) return plainText(message);
    final lines =
        value.content.split('\n').where((line) => line.trim().isNotEmpty);
    return lines.isEmpty
        ? (value.emptyOutput == true ? 'No output' : state)
        : lines.first;
  }

  List<String> details({bool technical = false}) {
    final value = result;
    final object = value == null ? null : _object(value.content);
    final old = call.input['oldString'];
    final replacement = call.input['newString'];
    return [
      if (description != null) ...[
        'Action: ${plainText(description!.fields.containsKey('Command') ? description!.title : description!.summary)}',
        for (final entry in description!.fields.entries)
          '${plainText(entry.key)}: ${plainText(entry.value)}',
      ],
      if (progressHistory.isNotEmpty) ...[
        'Progress',
        ...progressHistory.map((s) => '  $s')
      ],
      if (value?.isError == true) ...[
        'Error: $summary',
        if (object?['code'] is String)
          'Code: ${plainText(object!['code'] as String)}',
        if (object?['recovery'] is String)
          'Recovery: ${plainText(object!['recovery'] as String)}',
        if (object?['currentContext'] != null)
          'Current context: ${_pretty(object!['currentContext'])}',
      ],
      if (old is String && replacement is String) ...[
        value?.isError == false
            ? 'Successful replacement'
            : 'Requested replacement (not confirmed applied)',
        'Preview of arguments; not a whole-file diff',
        ...replacementDiff(old, replacement),
      ],
      if (technical) ...[
        'Call: ${plainText(call.id)}',
        'Arguments',
        _pretty(call.input),
      ],
      if (output.isNotEmpty) ...['Live output', output],
      if (truncated) '[live output truncated]',
      if (value != null && (object == null || !value.isError || technical)) ...[
        'Result',
        value.content
      ],
    ];
  }
}

Map<String, dynamic>? _object(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } catch (_) {
    return null;
  }
}

String _pretty(Object? value) {
  Object? redact(Object? v) => switch (v) {
        Map v => {
            for (final entry in v.entries)
              '${entry.key}': RegExp(
                          r'(password|secret|token|api[_-]?key|authorization)',
                          caseSensitive: false)
                      .hasMatch('${entry.key}')
                  ? '[redacted]'
                  : redact(entry.value)
          },
        List v => v.take(100).map(redact).toList(),
        String v => bounded(plainText(v), 8192),
        _ => v,
      };
  return bounded(
      const JsonEncoder.withIndent('  ').convert(redact(value)), 16384);
}

/// Bounded line diff. Common context stays visible; '+' and '-' never imply
/// the requested edit actually succeeded. The caller supplies that status.
List<String> replacementDiff(String before, String after) {
  final a = bounded(plainText(before)).split('\n');
  final b = bounded(plainText(after)).split('\n');
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final old = a.sublist(prefix, a.length - suffix);
  final fresh = b.sublist(prefix, b.length - suffix);
  final rows = <String>[
    if (prefix > 3) '  … unchanged context …',
    ...a
        .skip(prefix > 3 ? prefix - 3 : 0)
        .take(prefix > 3 ? 3 : prefix)
        .map((s) => '  $s')
  ];
  if (old.length > 160 || fresh.length > 160) {
    rows.addAll(old.take(80).map((s) => '- $s'));
    rows.addAll(fresh.take(80).map((s) => '+ $s'));
    rows.add('[large replacement: preview truncated]');
  } else {
    final lengths =
        List.generate(old.length + 1, (_) => List.filled(fresh.length + 1, 0));
    for (var i = old.length - 1; i >= 0; i--) {
      for (var j = fresh.length - 1; j >= 0; j--) {
        lengths[i][j] = old[i] == fresh[j]
            ? lengths[i + 1][j + 1] + 1
            : (lengths[i + 1][j] >= lengths[i][j + 1]
                ? lengths[i + 1][j]
                : lengths[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < old.length || j < fresh.length) {
      if (i < old.length && j < fresh.length && old[i] == fresh[j]) {
        rows.add('  ${old[i++]}');
        j++;
      } else if (i < old.length &&
          (j == fresh.length || lengths[i + 1][j] >= lengths[i][j + 1])) {
        rows.add('- ${old[i++]}');
      } else {
        rows.add('+ ${fresh[j++]}');
      }
    }
  }
  rows.addAll(a.skip(a.length - suffix).take(3).map((s) => '  $s'));
  if (suffix > 3) rows.add('  … unchanged context …');
  return rows.map((s) => bounded(s, 500)).toList();
}

/// A bounded view of the transcript plus live observations. Never writes logs.
final class ActivityModel {
  ActivityModel({this.capacity = 80});
  final int capacity;
  ToolDescription? Function(ToolUse)? describe;
  final records = <ActivityRecord>[];
  ActivityRecord record(ToolUse call,
      {bool historical = false, bool fresh = false}) {
    if (!fresh)
      for (final row in records.reversed) {
        if (row.call.id == call.id) return row;
      }
    ToolDescription? description;
    try {
      description = describe?.call(call);
    } catch (_) {}
    final row =
        ActivityRecord(call, historical: historical, description: description);
    records.add(row);
    if (records.length > capacity) records.removeAt(0);
    return row;
  }

  void event(ToolActivity event) {
    final previous = record(event.call);
    if (previous.finished && event is! ToolStarted) return;
    final row = event is ToolStarted && previous.finished
        ? record(event.call, fresh: true)
        : previous;
    switch (event) {
      case ToolStarted():
        row.state = 'running';
        row.started = DateTime.now();
      case ToolOutput(:final text):
        row.append(text);
      case ToolProgress(:final status):
        if (row.finished) return;
        row.progress = bounded(plainText(status), 1000);
        row.progressHistory.add(row.progress);
        if (row.progressHistory.length > 20) row.progressHistory.removeAt(0);
      case ToolFinished(:final result):
        row.finish(result);
    }
  }

  List<ActivityRecord> entry(SessionEntry entry, LogEvent event) {
    final completed = <ActivityRecord>[];
    if (entry is MessageAppendedEntry) {
      for (final block in entry.message.content) {
        if (block is ToolUseBlock)
          record(ToolUse.fromBlock(block),
              historical: event == LogEvent.replay, fresh: true);
        if (block is ToolResultBlock) {
          final matches = records.where((r) => r.call.id == block.toolUseId);
          if (matches.isNotEmpty && !matches.last.finished) {
            final row = matches.last;
            row.finish(ToolResult(block.content, isError: block.isError));
            completed.add(row);
          }
        }
      }
    }
    if (entry is TurnEndedEntry) {
      for (final row in records.where((r) => !r.finished)) {
        row.state = entry.reason == TurnStopReason.cancelled
            ? 'cancelled'
            : 'interrupted';
      }
    }
    return completed;
  }
}
