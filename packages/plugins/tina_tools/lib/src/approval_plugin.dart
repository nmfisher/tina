import 'dart:io';

import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_host/tina_host.dart';
import 'package:path/path.dart' as path;
import '../tina_tools.dart';

const toolProvider = PluginCapability<ToolSessionSource>('tina/tool-provider');
const modePolicySource = PluginCapability<ModePolicySource>('tina/mode-policy');

/// Plugin-owned integration. The application supplies filesystem/tool options;
/// the loader supplies the approval capability, never a particular channel.
PluginDefinition<C> toolsDefinition<C>(ToolsPlugin Function(C) tools) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/tools',
        settings: [
          readOnlyDirectoriesSetting,
          writeDirectoriesSetting,
          homeCachesSetting
        ],
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
        ApprovalDecision.allowWorkspace ||
        ApprovalDecision.allowGlobal ||
        ApprovalDecision.allowReadsInDirectory ||
        ApprovalDecision.allowAlwaysAndReadsInDirectory ||
        ApprovalDecision.allowWritesInDirectory ||
        ApprovalDecision.allowAlwaysAndWritesInDirectory =>
          Approval.no,
        ApprovalDecision.deny =>
          throw SandboxViolation('$reason — approval denied or cancelled'),
      };
    };

Approval _answer(ApprovalDecision decision, String reason) =>
    switch (decision) {
      ApprovalDecision.allow => Approval.yes,
      ApprovalDecision.allowAlways => Approval.always,
      ApprovalDecision.allowWorkspace ||
      ApprovalDecision.allowGlobal ||
      ApprovalDecision.allowReadsInDirectory ||
      ApprovalDecision.allowAlwaysAndReadsInDirectory ||
      ApprovalDecision.allowWritesInDirectory ||
      ApprovalDecision.allowAlwaysAndWritesInDirectory =>
        Approval.no,
      ApprovalDecision.deny =>
        throw SandboxViolation('$reason — approval denied or cancelled'),
    };

/// Connect enforcement boundaries to the shared mode policy.
void attachModePolicy(ToolsPlugin plugin) {
  plugin.sandbox.approver = (request, reason) async {
    final writeDirectory =
        request.op == FileOp.write ? path.dirname(request.path) : null;
    final decision = await plugin.modePolicy.request(
      operation: request.op.name,
      target: request.path,
      reason: reason,
      context: {
        'workspace': plugin.workingDirectory,
        'description':
            plugin.describeFileRequest(request.op.name, request.path).toJson(),
        'permission_scope': 'file',
        if (writeDirectory != null) 'write_directory': writeDirectory,
      },
    );
    if ((decision == ApprovalDecision.allowWritesInDirectory ||
            decision == ApprovalDecision.allowAlwaysAndWritesInDirectory) &&
        writeDirectory != null) {
      plugin.rememberWriteDirectory(writeDirectory);
      return decision == ApprovalDecision.allowWritesInDirectory
          ? Approval.yes
          : Approval.always;
    }
    return _answer(decision, reason);
  };
  plugin.processRunner.directoryApprover =
      (request, candidate, retry, isActive) async {
    if (!isActive() ||
        !plugin.osPlan.canGrant(candidate.path, write: candidate.write))
      return false;
    final target = canonicalSandboxPath(candidate.path);
    var directory =
        Directory(target).existsSync() ? target : path.dirname(target);
    while (!Directory(directory).existsSync()) {
      final parent = path.dirname(directory);
      if (parent == directory) return false;
      directory = parent;
    }
    // Never turn a failed creation into a root/home-wide grant.
    if (directory == path.separator ||
        directory == plugin.osPlan.hostHome ||
        !plugin.osPlan.canGrant(directory)) return false;
    final access = candidate.write ? 'write' : 'read';
    final setting =
        candidate.write ? writeDirectoriesSetting : readOnlyDirectoriesSetting;
    final scope = plugin.settings == null
        ? 'session'
        : (plugin.settings!.read(setting).source?.name ?? 'global');
    final decision = await plugin.modePolicy.request(
      operation: 'Grant directory access',
      target: directory,
      humanOnly: true,
      kind: ApprovalKind.confirmation,
      reason: 'The command needs $access access to ${candidate.path}. '
          'Grant $scope $access access to $directory and '
          '${retry ? "rerun" : "run"} this command? '
          '${retry ? "The previous attempt may already have changed files. " : ""}'
          'Protected credentials remain excluded.',
      context: {
        'description': ToolDescription(
            title: '${retry ? "Retry" : "Run"} with directory access',
            target: directory,
            fields: {
              'Command': CommandGrants.lineOf(request),
              'Access': '$scope $access: $directory'
            }).toJson(),
        'cwd': request.workingDirectory,
      },
    );
    if (decision != ApprovalDecision.allow || !isActive()) return false;
    if (candidate.write) {
      plugin.rememberWriteDirectory(directory);
    } else {
      plugin.rememberReadDirectory(directory);
    }
    return true;
  };
  plugin.processRunner.commandApprover = (request, review) async {
    final network =
        review.requiredPermissions.contains(ProcessPermission.network);
    final outsideSandbox =
        review.requiredPermissions.contains(ProcessPermission.unconfined);
    if (outsideSandbox &&
        plugin.commandApprovals.covers(request, review.requiredPermissions)) {
      return Approval.yes;
    }
    final description = describeCommandRequest(request);
    final decision = await plugin.modePolicy.request(
      operation: 'run command',
      target: [request.command, ...request.arguments].join(' '),
      reason: review.reason,
      humanOnly: outsideSandbox,
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
        if (outsideSandbox) 'sandbox_reason': review.sandboxReason,
        'description': (outsideSandbox
                ? ToolDescription(
                    title: '${description.title} outside sandbox',
                    target: description.target,
                    fields: {
                        ...description.fields,
                        'Access':
                            'Host filesystem and network for this subprocess tree',
                      })
                : network
                    ? ToolDescription(
                        title: '${description.title} with network access',
                        target: description.target,
                        fields: description.fields)
                    : description)
            .toJson(),
        'permission_scope': 'command',
        if (outsideSandbox && plugin.commandApprovals.file != null)
          'persistent_command_approval': true,
        if (review.readDirectory != null &&
            plugin.osPlan.canGrant(review.readDirectory!))
          'read_directory': review.readDirectory,
        if (outsideSandbox) ...{
          'permission_scope_label': 'this exact command outside the sandbox',
          'permission_scope_description':
              'Session/workspace: exact executable, arguments, directory, environment and input. '
                  'Global: same executable, arguments, environment and input in any directory. '
                  'Grants host filesystem, real HOME credentials and network access. '
                  'Revoke in Settings → Permissions.',
        } else if (network) ...{
          'permission_scope_label': 'this command with network access',
          'permission_scope_description':
              'Session approval covers this exact command, directory, environment '
                  'and input, including network access for its subprocess tree.',
        },
      },
    );
    if (outsideSandbox &&
        {
          ApprovalDecision.allowAlways,
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal
        }.contains(decision)) {
      if (!review.isActive()) return Approval.no;
      plugin.commandApprovals.remember(
          request,
          review.requiredPermissions,
          switch (decision) {
            ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
            ApprovalDecision.allowGlobal => CommandApprovalScope.global,
            _ => CommandApprovalScope.session,
          });
      return Approval.yes;
    }
    if ((decision == ApprovalDecision.allowReadsInDirectory ||
            decision == ApprovalDecision.allowAlwaysAndReadsInDirectory) &&
        review.readDirectory != null &&
        plugin.osPlan.canGrant(review.readDirectory!)) {
      plugin.rememberReadDirectory(review.readDirectory!);
    }
    return switch (decision) {
      ApprovalDecision.allow => Approval.yes,
      ApprovalDecision.allowAlways => Approval.always,
      ApprovalDecision.allowReadsInDirectory =>
        review.readDirectory != null ? Approval.yes : Approval.no,
      ApprovalDecision.allowAlwaysAndReadsInDirectory =>
        review.readDirectory != null ? Approval.always : Approval.no,
      ApprovalDecision.allowWorkspace ||
      ApprovalDecision.allowGlobal ||
      ApprovalDecision.allowWritesInDirectory ||
      ApprovalDecision.allowAlwaysAndWritesInDirectory =>
        Approval.no,
      ApprovalDecision.deny => Approval.no,
    };
  };
}
