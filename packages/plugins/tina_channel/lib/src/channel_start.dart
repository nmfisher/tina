import 'package:tina_engine_2/tina_engine_2.dart';

import 'channel_tools.dart' show truncated;
import '../channel_store_api.dart' show normalizeChannelName;

/// The user-approval seam for `channel_start`. The assembly wires this
/// to the session's approval machinery as a Yes/No confirmation that
/// shows WHAT is being created: the [channel] name, the [purpose], and
/// [members] (who will join). True creates the chat; false — declined,
/// cancelled or timed out — creates nothing.
typedef ChannelStartApprover = Future<bool> Function(
    {required String channel, String? purpose, required String members});

/// The `channel_start` tool schema. Starting a group chat is a
/// proposal the USER decides: the call is approval-gated, one ask per
/// user turn, main agents only. The tool is advertised in every
/// session (dormant included, subagents included) so a call always
/// reaches this executor and gets a NAMED refusal instead of an
/// unknown-tool error.
final channelStartTool = ToolSchema(
  name: 'channel_start',
  description: 'Ask the user to approve a group chat for this session. '
      'Do not start one unprompted: propose a chat only when coordination '
      'across multiple subagents is genuinely needed, and the user decides. '
      'One ask per user turn — a decline is final for that turn. On '
      'approval the chat is created (persisted with the session) and the '
      'channel pane appears for the user; subagents join the chat only '
      'in swarm mode — launch_subagent with channel: true (independent '
      'subagents, the default, never see it). Main agent only; a '
      'subagent call is refused. If a chat is already started the call '
      'reports that and creates nothing.',
  inputSchema: const {
    'type': 'object',
    'properties': {
      'channel': {
        'type': 'string',
        'description': "Channel name; '#' added and lowercased when "
            'missing (#lobby, the default meeting point).'
      },
      'purpose': {
        'type': 'string',
        'description': 'One line, at most 200 characters: what the chat '
            'is for. Shown to the user in the approval.'
      }
    }
  },
  describe: (input) => ToolDescription(
    title: 'Start group chat',
    target: '${input['channel'] ?? '#lobby'}',
    fields: {'Purpose': '${truncated('${input['purpose'] ?? ''}', 60)}'},
  ),
);

/// Parses and validates `channel_start` input: the channel (default
/// `#lobby`, normalized like every channel name) and the purpose (one
/// bounded line, optional). Throws [FormatException] on bad shapes.
(String, String?) parseChannelStartInput(Map<String, Object?> input) {
  final rawChannel = input['channel'];
  if (rawChannel != null && rawChannel is! String) {
    throw const FormatException('channel must be a string');
  }
  final channel = rawChannel is String && rawChannel.trim().isNotEmpty
      ? normalizeChannelName(rawChannel)
      : '#lobby';
  final rawPurpose = input['purpose'];
  if (rawPurpose != null && rawPurpose is! String) {
    throw const FormatException('purpose must be a string');
  }
  if (rawPurpose is String && rawPurpose.length > 200) {
    throw const FormatException('purpose must be at most 200 characters');
  }
  String? purpose;
  if (rawPurpose is String && rawPurpose.trim().isNotEmpty) {
    purpose = rawPurpose;
  }
  return (channel, purpose);
}
