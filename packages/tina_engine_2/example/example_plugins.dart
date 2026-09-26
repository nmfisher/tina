/// Four small plugins, one per hook group, so the hooks are visible in use.
///
/// Import this file from tests or examples; it is not exported by the
/// barrel on purpose — examples are not API.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

/// Adds a prompt section. Shows the core owns the join: the plugin returns
/// one section, never a whole prompt.
final class SystemSectionPlugin extends AgentPlugin {
  const SystemSectionPlugin(this._section);

  final String _section;

  @override
  String get id => 'example.system-section';

  @override
  int get order => 200;

  @override
  String? systemSection(Context c) => _section;
}

/// A guard. Denies every call to one tool name; all guards must pass, so a
/// denied call never reaches an executor, and the recorded result says why.
final class GuardPlugin extends AgentPlugin {
  const GuardPlugin(this.toolName, {this.reason = 'not allowed'});

  final String toolName;
  final String reason;

  @override
  String get id => 'example.guard';

  @override
  int get order => 50;

  @override
  Decision beforeTool(Context c, ToolCall call) =>
      call.name == toolName ? Decision.deny(reason) : const Decision.allow();
}

/// Contributes a tool and its executor wiring is left to the host: the tool
/// is advertised to the model here, the executor is registered on the loop.
final class ToolProviderPlugin extends AgentPlugin {
  const ToolProviderPlugin();

  @override
  String get id => 'example.tool-provider';

  @override
  List<Tool> get tools => const [
        Tool('echo', 'Echo its input back.',
            {'type': 'object', 'properties': {'text': {'type': 'string'}}}),
      ];
}

/// Rewrites every request. The seam a pruning or redaction plugin uses:
/// the request is a snapshot, so history itself is never touched.
final class RequestTransformerPlugin extends AgentPlugin {
  const RequestTransformerPlugin({this.suffix = ''});

  final String suffix;

  @override
  String get id => 'example.request-transformer';

  @override
  int get order => 300;

  @override
  Request? beforeRequest(Context c, Request request) => Request(
      systemPrompt: request.systemPrompt + suffix,
      messages: request.messages,
      tools: request.tools);
}
