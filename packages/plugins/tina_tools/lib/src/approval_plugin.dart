import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_host/tina_host.dart';
import '../tina_tools.dart';

const toolProvider = PluginCapability<ToolSessionSource>('tina/tool-provider');
const modePolicySource = PluginCapability<ModePolicySource>('tina/mode-policy');

/// Plugin-owned integration. The application supplies filesystem/tool options;
/// the loader supplies the approval capability, never a particular channel.
PluginDefinition<C> toolsDefinition<C>(ToolsPlugin Function(C) tools) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/tools',
        dependency: approvalRequester,
        provides: [toolProvider, modePolicySource],
        create: (context, approvals) {
      final plugin = tools(context);
      plugin.modePolicy.approvals = approvals;
      return plugin;
    },
        description:
            'Provides file, search and shell tools, enforcing sandbox permissions and approval decisions.');

Approver requesterApprover(ApprovalRequester approvals) =>
    (operation, reason) async {
      final decision = await approvals.request(
          operation: operation.op.name, target: operation.path, reason: reason);
      return switch (decision) {
        ApprovalDecision.allow => Approval.yes,
        ApprovalDecision.allowAlways => Approval.always,
        ApprovalDecision.deny =>
          throw SandboxViolation('$reason — approval denied or cancelled'),
      };
    };

Approval _answer(ApprovalDecision decision, String reason) =>
    switch (decision) {
      ApprovalDecision.allow => Approval.yes,
      ApprovalDecision.allowAlways => Approval.always,
      ApprovalDecision.deny =>
        throw SandboxViolation('$reason — approval denied or cancelled'),
    };

/// Connect enforcement boundaries to the shared mode policy.
void attachModePolicy(ToolsPlugin plugin) {
  plugin.sandbox.approver = (request, reason) async {
    final decision = await plugin.modePolicy.request(
      operation: request.op.name,
      target: request.path,
      reason: reason,
      context: {
        'workspace': plugin.workingDirectory,
        'description':
            plugin.describeFileRequest(request.op.name, request.path).toJson(),
        'permission_scope': 'file',
      },
    );
    return _answer(decision, reason);
  };
  plugin.processRunner.commandApprover = (request, review) async {
    final network =
        review.requiredPermissions.contains(ProcessPermission.network);
    final description = describeCommandRequest(request);
    final decision = await plugin.modePolicy.request(
      operation: 'run command',
      target: [request.command, ...request.arguments].join(' '),
      reason: review.reason,
      context: {
        'workspace': plugin.workingDirectory,
        'executable': request.command,
        'arguments': request.arguments,
        'cwd': request.workingDirectory,
        'environment': request.environment,
        'stdin': request.stdin,
        'required_permissions': [
          for (final p in review.requiredPermissions) p.name
        ],
        'missing_permissions': [
          for (final p in review.missingPermissions) p.name
        ],
        if (network) 'network_reason': review.networkReason,
        'description': (network
                ? ToolDescription(
                    title: '${description.title} with network access',
                    target: description.target,
                    fields: description.fields)
                : description)
            .toJson(),
        'permission_scope': 'command',
        if (network) ...{
          'permission_scope_label': 'this command with network access',
          'permission_scope_description':
              'Session approval covers this exact command, directory, environment '
                  'and input, including network access for its subprocess tree.',
        },
      },
    );
    return switch (decision) {
      ApprovalDecision.allow => Approval.yes,
      ApprovalDecision.allowAlways => Approval.always,
      ApprovalDecision.deny => Approval.no,
    };
  };
}
