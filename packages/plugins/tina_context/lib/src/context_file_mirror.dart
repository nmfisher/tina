import 'dart:convert';
import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';

import 'context_edit.dart';
import 'working_context.dart';

enum ContextEditStatus { unchanged, accepted, rejected }

final class ContextEditReceipt {
  const ContextEditReceipt(this.status, this.message);
  final ContextEditStatus status;
  final String message;
}

/// The file is an editing surface; the persisted log remains authoritative.
/// One mirror instance and one explicit path belong to one session.
final class ContextFileMirror {
  ContextFileMirror(this.file);

  final File file;
  WorkingContext? _exported;
  var _writeNumber = 0;
  ContextEditReceipt? lastReceipt;
  ContextEditReceipt? lastEditReceipt;
  String? _publishedText;

  /// Inspection never imports or repairs an edit.
  String get fileStatus {
    try {
      return file.readAsStringSync() == _publishedText
          ? 'Matches last export'
          : 'Pending file changes (not accepted)';
    } on FileSystemException {
      return 'Missing or unreadable (not accepted)';
    } on FormatException {
      return 'Pending file changes (not accepted)';
    }
  }

  /// Always overwrite leftovers on restart from restored persisted state.
  void initialize(WorkingContext context) {
    _publish(context);
    lastReceipt = null;
    lastEditReceipt = null;
  }

  /// Append entries that arrived after export to the edited base, preserving
  /// tool results from the very command that edited this file. The file's
  /// counters must match the export; the internal replacement uses today's
  /// counters. This is a controlled append rebase, not acceptance of arbitrary
  /// stale edits or concurrent replacements.
  WorkingContext synchronize(
      WorkingContext current, WorkingContext Function(List<Message>) replace) {
    final base = _exported;
    if (base == null) throw StateError('Context mirror is not initialized');
    var result = current;
    var receipt = const ContextEditReceipt(ContextEditStatus.unchanged, '');
    try {
      final Map<String, dynamic> document;
      final List<Message> edited;
      try {
        document = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if (document['schema_version'] != 1 ||
            document['revision'] != base.revision ||
            document['through_seq'] != base.throughSeq) {
          throw const FormatException('File version or counters changed');
        }
        edited = [
          for (final raw in document['messages'] as List)
            Message.fromJson(Map<String, dynamic>.from(raw as Map)),
        ];
      } on FileSystemException {
        throw const FormatException('Context file is missing or unreadable');
      } on TypeError {
        throw const FormatException('Invalid context file structure');
      } on ArgumentError {
        throw const FormatException('Invalid context message');
      }
      // Structural parse of the document stays here (it is file shape, not
      // edit validity); everything past parsing is evaluateContextEdit.
      if (!sameMessages(edited, base.messages)) {
        final verdict = evaluateContextEdit(
            current: current, edited: edited, base: base);
        switch (verdict) {
          case ContextEditUnchanged():
            break; // unreachable: edited differs from base by the check above
          case ContextEditRejectedVerdict():
            throw const FormatException('rejected');
          case ContextEditAccepted(:final merged):
            result = replace(merged);
            receipt = const ContextEditReceipt(
                ContextEditStatus.accepted, 'Context edit accepted.');
        }
      }
    } on FormatException {
      // Report a fixed receipt, never arbitrary parser or file contents.
      receipt = const ContextEditReceipt(
          ContextEditStatus.rejected,
          'Context edit rejected: invalid, stale, or protected content. '
          'The current working context was restored to the file.');
    }
    // Persistence errors from replace are not edit rejections and propagate.
    // Publish failures likewise prevent the next model request.
    _publish(result);
    lastReceipt = receipt;
    if (receipt.status != ContextEditStatus.unchanged)
      lastEditReceipt = receipt;
    return result;
  }

  void _publish(WorkingContext context) {
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp-$pid-${_writeNumber++}');
    try {
      final text = '${const JsonEncoder.withIndent('  ').convert({
            'schema_version': 1,
            'revision': context.revision,
            'through_seq': context.throughSeq,
            'messages': [for (final m in context.messages) m.toJson()],
          })}\n';
      temporary.writeAsStringSync(text, flush: true);
      temporary.renameSync(file.path);
      _exported = context;
      _publishedText = text;
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
}
