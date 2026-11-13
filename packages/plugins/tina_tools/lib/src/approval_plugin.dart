import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_host/tina_host.dart';
import '../tina_tools.dart';

const toolProvider = PluginCapability<ToolSessionSource>('tina/tool-provider');
const modePolicySource = PluginCapability<ModePolicySource>('tina/mode-policy');

/// Plugin-owned integration. The application supplies filesystem/tool options;
/// the loader supplies the approval capability, never a particular channel.
PluginDefinition<C> toolsDefinition<C>(ToolsPlugin Function(C) tools) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/tools',
        settings: executionSettings,
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
        ApprovalDecision.allowPrefixInSession ||
        ApprovalDecision.allowPrefixInWorkspace ||
        ApprovalDecision.allowReadsAlways ||
        ApprovalDecision.allowReadsInDirectory ||
        ApprovalDecision.allowAlwaysAndReadsInDirectory ||
        ApprovalDecision.allowWritesInDirectory ||
        ApprovalDecision.allowAlwaysAndWritesInDirectory =>
          Approval.no,
        ApprovalDecision.deny =>
          throw SandboxViolation('$reason — approval denied or cancelled'),
      };
    };

/// Resource approval is shared by file operations and sandboxed processes.
void attachModePolicy(ToolsPlugin plugin) {
  final root = canonicalSandboxPath(plugin.workingDirectory);
  bool inside(String target) => sandboxPathUnder(target, root);
  plugin.processRunner.workspaceWriteGranted =
      () => plugin.modePolicy.hasWorkspaceWriteGrant(root);
  plugin.processRunner.requestWorkspaceWrite =
      () => plugin.modePolicy.ensureWorkspaceWrite(root);

  Map<String, Object?> reviewPaths(List<PermissionAccess> accesses) {
    final reviewed = accesses.where((access) =>
        access.operation != PermissionAccessOperation.read ||
        !plugin.osPlan.allowsRuntimeRead(access.path));
    final offers = <Map<String, Object?>>[];
    final seen = <String>{};
    final saved = plugin.pathGrants.grants;
    void offer(String target, String access, bool recursive) {
      if (!plugin.osPlan.canGrant(target, write: access == 'write')) return;
      if (target == path.separator || target == plugin.osPlan.hostHome) return;
      if (seen.add('$target:$access:$recursive')) {
        offers.add({
          'path': target,
          'access': access,
          'recursive': recursive,
          'granted': saved.any((grant) =>
              (!recursive || grant.recursive) &&
              grant.covers(target, write: access == 'write')),
          'source': 'verified'
        });
      }
    }

    for (final access in reviewed) {
      if (inside(access.path) ||
          access.operation == PermissionAccessOperation.delete) continue;
      final directory = Directory(access.path).existsSync();
      final operation =
          access.operation == PermissionAccessOperation.read ? 'read' : 'write';
      offer(access.path, operation, directory);
      final parent = path.dirname(access.path);
      if (!directory && Directory(parent).existsSync())
        offer(parent, operation, true);
    }
    return {
      'resource_permissions': true,
      'accesses': [
        for (final a in reviewed) {...a.toJson(), 'source': 'verified'}
      ],
      'directory_accesses': offers,
      'directory_grant_scopes': ['workspace'],
      'persistent_command_approval': true,
      'permission_scope_label': 'selected file or directory access',
    };
  }

  bool save(List<DirectoryAccessGrant> grants, Map<String, Object?> details) {
    final offers = (details['directory_accesses'] as List).cast<Map>();
    for (final grant in grants) {
      if (grant.scope != DirectoryGrantScope.workspace ||
          !offers.any((offer) =>
              offer['path'] == grant.path &&
              offer['access'] == grant.access.name &&
              offer['recursive'] == grant.recursive) ||
          canonicalSandboxPath(grant.path) != grant.path ||
          !plugin.osPlan.canGrant(grant.path,
              write: grant.access == DirectoryAccess.write)) {
        return false;
      }
    }
    for (final grant in grants) {
      plugin.pathGrants.remember(grant.path,
          write: grant.access == DirectoryAccess.write,
          recursive: grant.recursive);
    }
    plugin.processRunner.writableDirectories
        .replace(plugin.osPlan.writableLayout());
    return true;
  }

  plugin.sandbox.approver = (request, reason) async {
    final workspace = inside(request.path);
    if (workspace && request.op == FileOp.read) return Approval.yes;
    if (request.op == FileOp.read &&
        plugin.osPlan.allowsRuntimeRead(request.path)) return Approval.yes;
    if (workspace) {
      return await plugin.modePolicy.ensureWorkspaceWrite(root)
          ? Approval.yes
          : Approval.no;
    }
    if (request.op != FileOp.delete &&
        plugin.pathGrants.allows(request.path,
            write: request.op == FileOp.write)) return Approval.yes;
    final operation = switch (request.op) {
      FileOp.read => PermissionAccessOperation.read,
      FileOp.write => PermissionAccessOperation.write,
      FileOp.delete => PermissionAccessOperation.delete,
    };
    final details = reviewPaths([
      PermissionAccess(
          operation,
          request.path,
          Directory(request.path).existsSync()
              ? PermissionTargetKind.directory
              : PermissionTargetKind.file)
    ]);
    List<DirectoryAccessGrant> grants = const [];
    final decision = await plugin.modePolicy.request(
      operation: request.op.name,
      target: request.path,
      reason: reason,
      authorization: AuthorizationRequest(requirements: [
        AccessRequirement(
            switch (request.op) {
              FileOp.read => AccessCapability.read,
              FileOp.write => AccessCapability.write,
              FileOp.delete => AccessCapability.delete,
            },
            request.path),
      ]),
      context: {
        ...details,
        'workspace': root,
        'permission_scope': 'file',
        'description':
            plugin.describeFileRequest(request.op.name, request.path).toJson()
      },
      onDirectoryGrants: (value) => grants = value,
    );
    if (decision == ApprovalDecision.deny) return Approval.no;
    if (decision == ApprovalDecision.allowPrefixInSession ||
        decision == ApprovalDecision.allowPrefixInWorkspace) return Approval.no;
    if (!save(grants, details)) return Approval.no;
    return Approval.yes;
  };
  plugin.sandbox.authorization = plugin.sandbox.approver;
  plugin.processRunner.directoryApprover = null;
  plugin.processRunner.commandApprover = (request, review) async {
    if (!review.isActive()) return Approval.no;
    final envelope = CapabilityEnvelope.parse(request,
        filteredEnvironment: true,
        searchPath: request.environment?['PATH'] ?? plugin.osPlan.searchPath);
    final accesses = <PermissionAccess>[
      ...envelope.verifiedAccesses,
      for (final target in review.directoryAccess.read)
        PermissionAccess(PermissionAccessOperation.read, target,
            PermissionTargetKind.directory),
      for (final target in review.directoryAccess.write)
        PermissionAccess(PermissionAccessOperation.write, target,
            PermissionTargetKind.directory),
      for (final target
          in review.authorization?.requirements ?? const <AccessRequirement>[])
        if (target.capability == AccessCapability.delete)
          PermissionAccess(PermissionAccessOperation.delete, target.target,
              PermissionTargetKind.unknown),
    ];
    final details = reviewPaths(accesses);
    String? prefixUnavailable;
    final prefixes = CommandPrefixPlan.parse(request,
        onUnavailable: (reason) => prefixUnavailable = reason,
        workspace: root,
        sandboxHomeRoot:
            review.requiredPermissions.contains(ProcessPermission.unconfined)
                ? null
                : plugin.home?.stateRoot,
        searchPath: request.environment?['PATH'] ?? plugin.osPlan.searchPath);
    final commandDescription = describeCommandRequest(request);
    final unconfined =
        review.requiredPermissions.contains(ProcessPermission.unconfined);
    final network =
        review.requiredPermissions.contains(ProcessPermission.network);
    final description = ToolDescription(
      title:
          '${commandDescription.title}${unconfined ? ' outside sandbox' : network ? ' with network access' : ''}',
      target: commandDescription.target,
      fields: {
        ...commandDescription.fields,
        if (unconfined)
          'Access': 'Host filesystem and network for this invocation',
        if (network && !unconfined)
          'Network': review.networkReason ?? 'Requested for this invocation',
      },
    );
    List<DirectoryAccessGrant> grants = const [];
    final decision = await plugin.modePolicy.request(
      operation: 'run command',
      target: approvalCommandText(request),
      reason: review.reason,
      authorization: review.authorization,
      context: {
        ...details,
        if (prefixes != null) 'command_prefixes': prefixes.labels,
        if (prefixUnavailable != null)
          'command_prefix_unavailable_reason': prefixUnavailable,
        if (prefixes != null)
          'persistent_command_prefix': plugin.commandApprovals.file != null,
        'workspace': root,
        'permission_scope': 'command',
        'access_coverage':
            envelope.completeVerifiedAccesses ? 'complete' : 'partial',
        'access_coverage_source': 'verified',
        'description': description.toJson(),
        'executable': request.command,
        'arguments': request.arguments,
        'cwd': request.workingDirectory,
        'stdin': request.stdin,
        'runtime_read_paths': plugin.osPlan.runtimeReadPaths,
        'required_permissions': [
          for (final p in review.requiredPermissions) p.name
        ],
        'approval_reason_codes': [
          if (!review.directoryAccess.isEmpty) 'missing_directory_access',
        ],
        'missing_permissions': [
          for (final p in review.missingPermissions) p.name
        ],
        'invocation_directory_access': review.directoryAccess.toJson(),
        'network_reason': review.networkReason,
        'sandbox_reason': review.sandboxReason,
      },
      onDirectoryGrants: (value) => grants = value,
    );
    if (decision == ApprovalDecision.deny || !review.isActive())
      return Approval.no;
    final prefixScope = switch (decision) {
      ApprovalDecision.allowPrefixInSession => CommandApprovalScope.session,
      ApprovalDecision.allowPrefixInWorkspace => CommandApprovalScope.workspace,
      _ => null,
    };
    if (!save(grants, details)) return Approval.no;
    if (prefixScope != null) {
      if (prefixes == null ||
          CommandPrefixPlan.parse(request,
                      workspace: root,
                      sandboxHomeRoot: review.requiredPermissions
                              .contains(ProcessPermission.unconfined)
                          ? null
                          : plugin.home?.stateRoot,
                      searchPath: request.environment?['PATH'] ??
                          plugin.osPlan.searchPath)
                  ?.identity !=
              prefixes.identity) return Approval.no;
      plugin.commandApprovals.rememberPrefixes(
          prefixes,
          {
            for (final requirement
                in review.authorization?.requirements ?? <AccessRequirement>[])
              requirement.capability.name,
          },
          prefixScope);
    }
    return Approval.yes;
  };
}
