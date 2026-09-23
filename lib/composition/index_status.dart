import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/index_status_renderer.dart';

/// Mounts the background-index progress indicator on the status strip beneath
/// the input (`/index` classification and the summary fleet).
///
/// Two contributions over the app-wide [IndexProgressStatus] service (provided
/// by [indexProgressPlugin], required here):
/// - the [IndexProgressStatus] itself as a [StatusSource] (it reads null while
///   no run is active, which removes the line from the strip), and
/// - the [IndexingStatusRenderer], painting the animated `indexing · 12/54`
///   line, left-aligned so it never competes with the right-aligned token
///   counter for the strip's single right group.
PluginDescriptor indexStatusPlugin() => PluginDescriptor(
  id: 'tina.index-status',
  requires: {indexProgressServiceKey},
  factory: FnPluginFactory((context) {
    final status = context.require(indexProgressServiceKey);
    context.register(status, id: 'tina.index-status.source');
    context.register(
      const IndexingStatusRenderer(),
      id: 'tina.index-status.renderer',
    );
    return Object();
  }),
);
