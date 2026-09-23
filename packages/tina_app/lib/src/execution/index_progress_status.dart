import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import 'input_status.dart';

/// The single live indexing-progress tracker, provided by [indexProgressPlugin]
/// under this key. Background job wiring looks it up through the plugin scope
/// (headless runs without the plugin simply pass null and skip the indicator);
/// the strip reads it through the [IndexProgressStatus] contribution registered
/// by the frontend's composition plugin.
final indexProgressServiceKey = ServiceKey<IndexProgressStatus>(
  'tina.index.progress',
);

/// Strip view-model for a running index: tasks settled so far and the
/// announced total. Value-shaped so the renderer stays a pure function;
/// `total == 0` means the run has not announced a size yet (or needs none).
class IndexProgress {
  final int done;
  final int total;
  const IndexProgress({required this.done, required this.total});
}

/// Live `done/total` progress for background index runs (`/index`
/// classification, the summary fleet), exposed to the status strip as a
/// [StatusSource]. App-scoped like the spend ledger: the supervisor allows one
/// job per kind, so every conversation reads the same snapshot; the refcount
/// keeps the indicator up if that ever loosens. `read` returns null while no
/// run is active, which removes the line from the strip.
class IndexProgressStatus implements StatusSource {
  var _runs = 0;
  int _done = 0;
  int _total = 0;
  final _changes = StreamController<void>.broadcast();

  /// True while at least one background index run is active.
  bool get running => _runs > 0;

  /// Mark a run started. Nesting is counted; counts reset only when the last
  /// run ends, so an overlapping start cannot clobber a live fraction.
  void begin() {
    _runs++;
    if (_runs == 1) {
      _done = 0;
      _total = 0;
    }
    _changes.add(null);
  }

  /// Report the orchestrator's settled/announced counts. Ignored when no run
  /// is active (a late callback after the job ended must not resurrect it).
  void progress(int done, int total) {
    if (!running) return;
    _done = done;
    _total = total;
    _changes.add(null);
  }

  /// Mark a run finished (completed, failed or cancelled).
  void end() {
    if (_runs == 0) return;
    _runs--;
    if (_runs == 0) {
      _done = 0;
      _total = 0;
    }
    _changes.add(null);
  }

  @override
  Object? read(String conversationId) =>
      running ? IndexProgress(done: _done, total: _total) : null;

  @override
  Stream<void> get changes => _changes.stream;

  /// Release the change stream. Called by the providing scope at teardown.
  void close() => _changes.close();
}

/// Provides the app-wide [IndexProgressStatus] under
/// [indexProgressServiceKey]. Mounted by the interactive composition; the
/// status-strip plugin requires the same key to contribute the source and
/// renderer that display it.
PluginDescriptor indexProgressPlugin() => PluginDescriptor(
  id: 'tina.index-progress',
  provides: [indexProgressServiceKey],
  factory: FnPluginFactory((context) {
    final status = IndexProgressStatus();
    context.own(status.close);
    return status;
  }),
);
