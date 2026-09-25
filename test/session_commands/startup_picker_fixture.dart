/// Shared fixtures for the startup-picker tests: a [SessionChoice] builder
/// and a fixed-geometry [TerminalGeometry].
library;

import 'package:tina_engine/tina_engine.dart';
import 'package:tina/session_commands/startup_session_picker_overlay.dart';
import 'package:tina/platform/terminal_geometry.dart';

/// The fixture timestamp all test sessions are anchored to.
final pickerNow = DateTime(2026, 09, 23, 12);

/// Convenience builder: one [SessionChoice] per (id, title, description).
SessionChoice choice(
  String id,
  String title, {
  String description = '',
  String when = '',
  DateTime? updated,
}) {
  return SessionChoice(
    meta: SessionMeta(
      id: id,
      title: title,
      createdAt: pickerNow,
      updatedAt: updated ?? pickerNow,
      messageCount: 1,
      conversationCount: 1,
      description: description.isEmpty ? null : description,
    ),
    title: title,
    description: description,
    when: when,
  );
}

/// Fixed-geometry [TerminalGeometry] for tests.
class FixedGeometry implements TerminalGeometry {
  @override
  final int columns;
  @override
  final int lines;
  @override
  bool get hasTerminal => false;
  const FixedGeometry(this.columns, this.lines);
}
