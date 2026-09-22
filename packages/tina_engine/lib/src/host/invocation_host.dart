import '../agent/agent_event_bus.dart';
import '../agent/invocation_sink.dart';
import '../permissions/preview.dart';
import '../permissions/prompt.dart';
import '../runtime/invocation.dart';
import 'host_interface.dart';

/// Borrowed host view for one invocation, including application status output.
/// Host lifecycle is forwarded directly so cancellation always clears activity.
class InvocationHost extends InvocationSink implements HostInterface {
  final HostInterface host;
  InvocationHost(this.host, Invocation invocation) : super(host, invocation);

  @override
  AgentEventBus get eventBus => host.eventBus;
  @override
  Future<PermissionResponse> askPermission(PermissionPrompt prompt) async {
    try {
      while (invocation!.isHeld && !invocation!.isCancelled) {
        await invocation!.ready();
      }
      if (invocation!.isCancelled || invocation!.isDone)
        return PermissionResponse.denyOnce;
      return await host.askPermission(prompt);
    } on InvocationCancelled {
      return PermissionResponse.denyOnce;
    }
  }

  @override
  void showPreview(List<PreviewEntry> preview) =>
      invocation!.output(() => host.showPreview(preview));
  @override
  void showMessage(String message,
          {HostMessageStyle style = HostMessageStyle.normal}) =>
      invocation!.output(() => host.showMessage(message, style: style),
          size: message.length);
  @override
  void showSeparator() => invocation!.output(host.showSeparator);
  @override
  void clear() => invocation!.output(host.clear);
  @override
  void setActivity(bool active) => host.setActivity(active);
  @override
  void setIdle(bool active) => host.setIdle(active);
  @override
  void setActive(bool active) => host.setActive(active);
  @override
  void handleResize() => host.handleResize();
  @override
  Future<void> dispose() async {} // A borrowed view never disposes its host.
}
