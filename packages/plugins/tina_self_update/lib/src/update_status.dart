import 'package:tina_host/tina_host.dart';

enum UpdatePhase { current, checking, available, failed, deferred }

final class UpdateStatus {
  const UpdateStatus(this.phase, {this.tag, this.reason, this.until});
  final UpdatePhase phase;
  final String? tag, reason;
  final DateTime? until;
}

/// Channel-independent release status. A frontend may start the once-per-load
/// background probe; headless commands still check explicitly via /update.
abstract interface class UpdateStatusSource {
  UpdateStatus get status;
  Stream<void> get changes;
  Future<void> checkInBackground();
}

const updateStatusSource =
    PluginCapability<UpdateStatusSource>('tina/update-status');
