import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/version_status_renderer.dart';

/// Mounts the release-check indicator on the status strip beneath the input.
///
/// Two contributions over the app-wide [VersionStatus] service (provided by
/// [versionStatusPlugin], required here):
/// - the [VersionStatus] itself as a [StatusSource] (it reads null while
///   idle, which removes the line from the strip), and
/// - the [VersionStatusRenderer], painting the animated `update check |`
///   spinner while the check runs and the persistent `update ⬆ v0.9.0 ·
///   /update` alert (theme yellow) when a newer release is out — left-aligned
///   so it never competes with the right-aligned token counter for the
///   strip's single right group.
PluginDescriptor versionStatusUiPlugin() => PluginDescriptor(
  id: 'tina.version-status',
  requires: {versionStatusServiceKey},
  factory: FnPluginFactory((context) {
    final status = context.require(versionStatusServiceKey);
    context.register(status, id: 'tina.version-status.source');
    context.register(
      const VersionStatusRenderer(),
      id: 'tina.version-status.renderer',
    );
    return Object();
  }),
);
