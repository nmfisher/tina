import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_host/tina_host.dart';
import '../tina_tools.dart';

/// Plugin-owned integration. The application supplies filesystem/tool options;
/// the loader supplies the approval capability, never a particular channel.
PluginDefinition<C> toolsDefinition<C>(ToolsPlugin Function(C) tools) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/tools',
        dependency: approvalRequester, create: (context, approvals) {
      final plugin = tools(context);
      plugin.sandbox.approver = requesterApprover(approvals);
      plugin.processRunner.commandApprover = (request, reason) async {
        final decision = await approvals.request(
          operation: 'run command',
          target: [request.command, ...request.arguments].join(' '),
          reason: reason,
        );
        return switch (decision) {
          ApprovalDecision.allow => Approval.yes,
          ApprovalDecision.allowAlways => Approval.always,
          ApprovalDecision.deny => Approval.no,
        };
      };
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
