import 'package:tina_engine/tina_engine.dart';

import 'fake_agent_sink.dart';

/// An in-memory [HostInterface] for tests that exercise session/controller
/// logic without a terminal. Records every host-facing call (messages,
/// separators, clears, activity/idle/active signals, resizes, previews,
/// permission asks) and delegates the [AgentSink] surface to a wrapped
/// [FakeAgentSink], so sink assertions reuse the same vocabulary as
/// [FakeAgentSink]-based tests. Touches no terminal type, so tests using it
/// need not import `tina_console`.
class FakeHostInterface implements HostInterface {
  FakeHostInterface({this.permissionResponse = PermissionResponse.denyOnce});

  /// Answer returned by [askPermission]. Tests override to drive allow/deny.
  PermissionResponse permissionResponse;

  final FakeAgentSink _sink = FakeAgentSink();
  final AgentEventBus _bus = AgentEventBus();

  /// Recorded [showMessage] texts, in call order (any style).
  final List<String> messages = [];

  /// Recorded [showMessage] calls with their style.
  final List<({String message, HostMessageStyle style})> styledMessages = [];

  /// Recorded [showPreview] calls.
  final List<List<PreviewEntry>> previews = [];

  /// [setActivity] arguments, in call order.
  final List<bool> activitySignals = [];

  /// [setIdle] arguments, in call order.
  final List<bool> idleSignals = [];

  /// [setActive] arguments, in call order — the active-conversation handoff
  /// signal multi-session UIs key off.
  final List<bool> activeChanges = [];

  int separators = 0;
  int clears = 0;
  int handleResizeCalls = 0;
  int disposeCalls = 0;

  /// The last [setActive] value — whether this conversation's surface is
  /// currently the active one. False before any call (a fresh host is detached).
  bool get isActive => activeChanges.isEmpty ? false : activeChanges.last;

  /// Convenience inverse of [isActive] — the UI-agnostic equivalent of a chat
  /// region's `isDetached`.
  bool get isDetached => !isActive;

  /// The wrapped recording sink — use this for sink-side assertions
  /// (`host.sink.texts`, `.toolStarts`, …).
  FakeAgentSink get sink => _sink;

  /// Convenience: every notice message recorded by the sink.
  List<String> get notices =>
      _sink.notices.map((n) => n.message).toList(growable: false);

  // --- HostInterface surface ---

  @override
  AgentEventBus get eventBus => _bus;

  @override
  Future<PermissionResponse> askPermission(PermissionPrompt prompt) async =>
      permissionResponse;

  @override
  void showPreview(List<PreviewEntry> preview) => previews.add(preview);

  @override
  void showMessage(String message,
      {HostMessageStyle style = HostMessageStyle.normal}) {
    messages.add(message);
    styledMessages.add((message: message, style: style));
  }

  @override
  void showSeparator() => separators++;

  @override
  void clear() => clears++;

  @override
  void setActivity(bool active) => activitySignals.add(active);

  @override
  void setIdle(bool active) => idleSignals.add(active);

  @override
  void setActive(bool active) => activeChanges.add(active);

  @override
  void handleResize() => handleResizeCalls++;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _bus.dispose();
  }

  // --- AgentSink surface (delegated to the recording sink) ---

  @override
  void text(String s) => _sink.text(s);

  @override
  void newline() => _sink.newline();

  @override
  void toolStart(ToolStartEvent event) => _sink.toolStart(event);

  @override
  void toolOutput(ToolOutputEvent event) => _sink.toolOutput(event);

  @override
  void toolComplete(ToolCompleteEvent event) => _sink.toolComplete(event);

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) =>
      _sink.notice(message, kind: kind);

  @override
  void activityStart() => _sink.activityStart();

  @override
  void activityStop() => _sink.activityStop();
}
