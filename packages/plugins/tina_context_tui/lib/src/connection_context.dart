import 'package:tina_context/observation.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

/// An on-demand inspector of accepted context, never of the editing file.
/// History is read at one published boundary and discarded after projection.
final class ConnectionContextObservation implements ContextObservation {
  ConnectionContextObservation(this._connection);
  final SessionConnection _connection;
  Map _data = const {};
  int _throughSeq = -2;
  bool _pending = false;
  WorkingContext? _context;
  ({WorkingContext before, WorkingContextSnapshot after})? _change;
  String? _unavailable;

  @override
  void refresh() {
    final attachment = _connection.attach();
    try {
      final snapshot = attachment.initial;
      final data = snapshot.features['tina/context'] as Map?;
      if (data == null) {
        throw StateError('Context details unavailable');
      }
      final pending = data['include_pending_turn'] == true;
      if (_throughSeq != snapshot.throughSeq ||
          _pending != pending ||
          _context == null) {
        final entries = <SessionEntry>[];
        var after = -1;
        while (after < snapshot.throughSeq) {
          final page = attachment.history(snapshot: snapshot, afterSeq: after);
          if (page.nextAfterSeq <= after)
            throw StateError('History did not advance');
          entries.addAll(page.entries.map((entry) =>
              SessionEntry.fromJson(Map<String, dynamic>.from(entry))));
          after = page.nextAfterSeq;
        }
        final context =
            deriveWorkingContext(entries, includePendingTurn: pending);
        final change =
            deriveLatestContextChange(entries, includePendingTurn: pending);
        _context = context;
        _change = change;
        _throughSeq = snapshot.throughSeq;
        _pending = pending;
      }
      if (!snapshot.historyPublicationFailed &&
          (_context!.revision != data['revision'] ||
              _context!.throughSeq != data['through_seq'])) {
        throw StateError('Context revision unavailable');
      }
      _data = data;
      _unavailable = null;
      if (snapshot.historyPublicationFailed) {
        // Only committed history is trustworthy after a failed publication.
        // File receipts and budget estimates may describe later, rejected work.
        _data = {
          'budget_tokens': data['budget_tokens'],
          'file_status': 'Live context unavailable; showing confirmed history'
        };
      }
    } catch (_) {
      _unavailable = 'Context details unavailable';
      _context = null;
      _change = null;
      _data = const {};
    } finally {
      attachment.close();
    }
  }

  @override
  WorkingContext get workingContext =>
      _context ??
      (throw StateError(_unavailable ?? 'Context has not been read'));
  @override
  bool get includePendingTurn => _pending;
  @override
  ContextBudgetUsage? get budgetUsage => _data['input_tokens'] == null
      ? null
      : ContextBudgetUsage(
          inputTokens: _data['input_tokens'] as int,
          budgetTokens: _data['usage_budget_tokens'] as int,
          responseReserveTokens: _data['response_reserve_tokens'] as int,
          reminder: null);
  @override
  int get budgetTokens => _data['budget_tokens'] as int? ?? 0;
  @override
  int? get latestEditTokensSaved => _data['last_edit_tokens_saved'] as int?;
  @override
  String get fileStatus => _data['file_status'] as String? ?? 'Unavailable';
  @override
  String? get mirrorPath => _data['mirror_path'] as String?;
  @override
  ContextEditReceipt? get lastEditReceipt {
    final receipt = _data['last_edit_receipt'] as Map?;
    return receipt == null
        ? null
        : ContextEditReceipt(
            ContextEditStatus.values.byName(receipt['status'] as String),
            receipt['message'] as String);
  }

  @override
  ({WorkingContext before, WorkingContextSnapshot after})? get latestChange =>
      _change;
}
