import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_host/tina_host.dart';
import 'package:path/path.dart' as path;
import '../tina_tools.dart';
import 'access_review.dart';
import 'read_only_commands.dart';
import 'command_workflow.dart';
import 'package:tina_settings/tina_settings.dart';

void _saveDirectoryGrants(
    ToolsPlugin plugin, List<DirectoryAccessGrant> grants) {
  for (final scope in DirectoryGrantScope.values) {
    final selected = grants.where((grant) => grant.scope == scope).toList();
    if (selected.isEmpty) continue;
    final settings = plugin.settings;
    if (settings == null) {
      if (scope != DirectoryGrantScope.session)
        throw const FormatException('No persistent directory storage');
      for (final grant in selected) {
        if (grant.access == DirectoryAccess.read) {
          plugin.rememberReadDirectory(grant.path);
        } else {
          plugin.rememberWriteDirectory(grant.path);
        }
      }
      continue;
    }
    final settingScope = SettingScope.values.byName(scope.name);
    settings.update(settingScope, {
      for (final access in DirectoryAccess.values)
        if (selected.any((grant) => grant.access == access))
          (access == DirectoryAccess.read
                  ? readOnlyDirectoriesSetting
                  : writeDirectoriesSetting)
              .id: {
            ...((settings.override(
                        access == DirectoryAccess.read
                            ? readOnlyDirectoriesSetting
                            : writeDirectoriesSetting,
                        settingScope) as List?)
                    ?.cast<String>() ??
                const <String>[]),
            ...selected
                .where((grant) => grant.access == access)
                .map((grant) => grant.path),
          }.toList(),
    });
  }
}

const toolProvider = PluginCapability<ToolSessionSource>('tina/tool-provider');
const modePolicySource = PluginCapability<ModePolicySource>('tina/mode-policy');

/// Plugin-owned integration. The application supplies filesystem/tool options;
/// the loader supplies the approval capability, never a particular channel.
PluginDefinition<C> toolsDefinition<C>(ToolsPlugin Function(C) tools) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/tools',
        settings: [
          readOnlyDirectoriesSetting,
          writeDirectoriesSetting,
          homeCachesSetting,
          allowReadsOutsideWorkspaceSetting
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

Approval _answer(ApprovalDecision decision, String reason) =>
    switch (decision) {
      ApprovalDecision.allow => Approval.yes,
      ApprovalDecision.allowAlways => Approval.always,
      ApprovalDecision.allowWorkspace ||
      ApprovalDecision.allowGlobal ||
      ApprovalDecision.allowReadsAlways ||
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
    if (request.op == FileOp.write && plugin.mode == PermissionMode.readOnly) {
      reason = 'read-only mode blocks writes. Change mode to edit.';
    }
    final readDirectory = request.op == FileOp.read
        ? Directory(request.path).existsSync()
            ? request.path
            : path.dirname(request.path)
        : null;
    final writeDirectory =
        request.op == FileOp.write ? path.dirname(request.path) : null;
    List<DirectoryAccessGrant> directoryGrants = const [];
    final verified = [
      PermissionAccess(
          request.op == FileOp.read
              ? PermissionAccessOperation.read
              : PermissionAccessOperation.write,
          request.path,
          Directory(request.path).existsSync()
              ? PermissionTargetKind.directory
              : PermissionTargetKind.file)
    ];
    final accessDetails = permissionAccessReview(
        plan: plugin.osPlan,
        cwd: plugin.workingDirectory,
        verified: verified,
        judgment: const PermissionJudgment(null),
        complete: true,
        persistent: plugin.settings != null);
    final decision = await plugin.modePolicy.request(
      authorization: AuthorizationRequest(requirements: [
        AccessRequirement(
            request.op == FileOp.read
                ? AccessCapability.read
                : AccessCapability.write,
            request.path,
            workspace: sandboxPathUnder(
                request.path, canonicalSandboxPath(plugin.workingDirectory)),
            granted: request.op == FileOp.read
                ? plugin.settings
                            ?.read(allowReadsOutsideWorkspaceSetting)
                            .value ==
                        true ||
                    plugin.readDirectories.allows(request.path) ||
                    plugin.writeDirectories.allows(request.path) ||
                    plugin.sandbox.readGrantsAllow(request.path) ||
                    plugin.sandbox.grants.allows(request.path) ||
                    plugin.commandApprovals.coversAccess('read', request.path)
                : plugin.writeDirectories.allows(request.path) ||
                    plugin.sandbox.grants.allows(request.path) ||
                    plugin.commandApprovals
                        .coversAccess('write', request.path)),
      ]),
      operation: request.op.name,
      target: request.path,
      reason: reason,
      onDirectoryGrants: (grants) => directoryGrants = grants,
      prepareAccessReview: (_) => accessDetails,
      context: {
        ...accessDetails,
        'workspace': plugin.workingDirectory,
        'description':
            plugin.describeFileRequest(request.op.name, request.path).toJson(),
        'permission_scope': 'file',
        'persistent_command_approval': plugin.commandApprovals.file != null,
        'permission_scope_label': 'this file',
        if (readDirectory != null) 'read_directory': readDirectory,
        if (writeDirectory != null) 'write_directory': writeDirectory,
      },
    );
    if (!validateDirectoryGrants(plugin.osPlan, directoryGrants, accessDetails))
      return Approval.no;
    if ({
      ApprovalDecision.allowAlways,
      ApprovalDecision.allowWorkspace,
      ApprovalDecision.allowGlobal
    }.contains(decision)) {
      plugin.commandApprovals.rememberAccess(
          request.op.name,
          request.path,
          switch (decision) {
            ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
            ApprovalDecision.allowGlobal => CommandApprovalScope.global,
            _ => CommandApprovalScope.session,
          });
      _saveDirectoryGrants(plugin, directoryGrants);
      return Approval.yes;
    }
    if (decision == ApprovalDecision.allowReadsAlways &&
        request.op == FileOp.read) {
      _saveDirectoryGrants(plugin, directoryGrants);
      final scope = directoryGrants.isEmpty
          ? DirectoryGrantScope.session
          : directoryGrants.first.scope;
      plugin.settings?.set(allowReadsOutsideWorkspaceSetting, true,
          SettingScope.values.byName(scope.name));
      return Approval.yes;
    }
    if ({ApprovalDecision.allow, ApprovalDecision.allowAlways}
        .contains(decision)) {
      _saveDirectoryGrants(plugin, directoryGrants);
    }
    if ((decision == ApprovalDecision.allowReadsInDirectory ||
            decision == ApprovalDecision.allowAlwaysAndReadsInDirectory) &&
        readDirectory != null) {
      plugin.rememberReadDirectory(readDirectory);
      return decision == ApprovalDecision.allowReadsInDirectory
          ? Approval.yes
          : Approval.always;
    }
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
  plugin.sandbox.authorization = plugin.sandbox.approver;
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
    List<DirectoryAccessGrant> directoryGrants = const [];
    final accessDetails = {
      'directory_accesses': [
        {'path': directory, 'access': access, 'source': 'verified'}
      ],
      'directory_grant_scopes': plugin.settings == null
          ? ['session']
          : ['session', 'workspace', 'global'],
      'directory_grant_required': true,
      'persistent_command_approval': plugin.settings != null,
      'accesses': [
        {
          'operation': access,
          'path': target,
          'target_kind': Directory(target).existsSync() ? 'directory' : 'file',
          'source': 'verified'
        }
      ],
      'access_coverage': 'partial',
    };
    final decision = await plugin.modePolicy.request(
      authorization: AuthorizationRequest(requirements: [
        AccessRequirement(
            candidate.write ? AccessCapability.write : AccessCapability.read,
            directory,
            workspace: false),
      ]),
      operation: 'Grant directory access',
      target: directory,
      humanOnly: true,
      reason: 'The command needs $access access to ${candidate.path}. '
          'Grant $access access to $directory and '
          '${retry ? "rerun" : "run"} this command? '
          '${retry ? "The previous attempt may already have changed files. " : ""}'
          'Protected credentials remain excluded.',
      context: {
        ...accessDetails,
        'description': ToolDescription(
            title: '${retry ? "Retry" : "Run"} with directory access',
            target: directory,
            fields: {
              'Command': CommandGrants.lineOf(request),
              'Access': '$access: $directory'
            }).toJson(),
        'cwd': request.workingDirectory,
      },
      onDirectoryGrants: (grants) => directoryGrants = grants,
    );
    if (!{
          ApprovalDecision.allow,
          ApprovalDecision.allowAlways,
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal
        }.contains(decision) ||
        !isActive() ||
        !validateDirectoryGrants(plugin.osPlan, directoryGrants, accessDetails))
      return false;
    if (decision != ApprovalDecision.allow)
      _saveDirectoryGrants(plugin, directoryGrants);
    return true;
  };
  plugin.processRunner.commandApprover = (request, review) async {
    final network =
        review.requiredPermissions.contains(ProcessPermission.network);
    final outsideSandbox =
        review.requiredPermissions.contains(ProcessPermission.unconfined);
    final settings = plugin.settings;
    final description = describeCommandRequest(request);
    final readerRequest = literalShellRequest(request) ?? request;
    final readerCandidate = outsideSandbox || network
        ? null
        : readOnlyExecutable(readerRequest,
            searchPath: plugin.processRunner.executableSearchPath,
            candidateOnly: true);
    final readerDigest = readerCandidate != null &&
            readOnlyExecutable(readerRequest,
                    searchPath: plugin.processRunner.executableSearchPath,
                    trustedExecutables:
                        plugin.commandApprovals.readerExecutables) ==
                null
        ? sha256.convert(File(readerCandidate).readAsBytesSync()).toString()
        : null;
    final workflow = outsideSandbox || network
        ? null
        : commandWorkflow(request, plugin.workingDirectory);
    String? commandPattern;
    List<DirectoryAccessGrant> directoryGrants = const [];
    final verified = verifiedReaderAccesses(request,
        searchPath: plugin.processRunner.executableSearchPath,
        trustedExecutables: plugin.commandApprovals.readerExecutables);
    final certified = hasCompleteReaderAccesses(request,
        searchPath: plugin.processRunner.executableSearchPath,
        trustedExecutables: plugin.commandApprovals.readerExecutables);
    Map<String, Object?> accessReview(PermissionJudgment judgment) {
      final details = permissionAccessReview(
          plan: plugin.osPlan,
          cwd: request.workingDirectory ?? plugin.workingDirectory,
          verified: verified,
          complete: certified,
          judgment: judgment,
          persistent: plugin.settings != null);
      final offers = (details['directory_accesses'] as List)
          .cast<Map<String, Object?>>()
          .toList();
      for (final access in ['read', 'write']) {
        for (final directory in access == 'read'
            ? review.directoryAccess.read
            : review.directoryAccess.write) {
          if (!offers.any((offer) =>
              offer['path'] == directory && offer['access'] == access)) {
            offers.add(
                {'path': directory, 'access': access, 'source': 'verified'});
          }
        }
      }
      return {
        ...details,
        'directory_accesses': offers,
        if (!review.directoryAccess.isEmpty)
          'invocation_directory_access': review.directoryAccess.toJson()
      };
    }

    var accessDetails = accessReview(const PermissionJudgment(null));
    final decision = await plugin.modePolicy.request(
      operation: 'run command',
      target: [request.command, ...request.arguments].join(' '),
      reason: review.reason,
      authorization: review.authorization,
      onCommandPattern: (pattern) => commandPattern = pattern,
      onDirectoryGrants: (grants) => directoryGrants = grants,
      prepareAccessReview: (judgment) => accessDetails = accessReview(judgment),
      context: {
        ...accessDetails,
        'workspace': plugin.workingDirectory,
        'executable': request.command,
        'arguments': request.arguments,
        'cwd': request.workingDirectory,
        'environment': request.environment,
        'stdin': request.stdin,
        'approval_identity': {
          'executable': request.command,
          'arguments': request.arguments,
          'cwd': request.workingDirectory,
          'environment': request.environment,
          'stdin': request.stdin,
          'directory_access': review.directoryAccess.toJson(),
        },
        'approval_reason_codes': [
          if (!review.directoryAccess.isEmpty) 'missing_directory_access',
          if (outsideSandbox) 'host_execution',
          if (plugin.commandApprovals.hasRelatedRule(request)) 'grant_mismatch',
        ],
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
        if (!outsideSandbox) 'recommended_scope': 'workspace',
        if (readerDigest != null) ...{
          'permission_scope_label': 'permitted reads with $readerCandidate',
          'permission_scope_description':
              'Remembering permits supported read-only arguments with this executable version. '
                  'Folder access, network and host execution require their own permissions.',
        } else if (workflow != null) ...{
          'permission_scope_label': '$workflow in this project',
          'permission_scope_description':
              'Workspace approval covers $workflow with supported options and project files, '
                  'including subdirectories. Global applies to other workspaces too. '
                  'Filesystem confinement and network permissions stay in effect.',
        },
        'command_pattern_target': approvalCommandText(request),
        if (plugin.commandApprovals.file != null)
          'persistent_command_pattern': true,
        if (plugin.commandApprovals.file != null)
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
    if (!review.isActive() ||
        !validateDirectoryGrants(plugin.osPlan, directoryGrants, accessDetails))
      return Approval.no;
    if (readerDigest != null &&
        readerCandidate != null &&
        sha256.convert(File(readerCandidate).readAsBytesSync()).toString() !=
            readerDigest) return Approval.no;
    if ({
      ApprovalDecision.allow,
      ApprovalDecision.allowAlways,
      ApprovalDecision.allowWorkspace,
      ApprovalDecision.allowGlobal
    }.contains(decision)) {
      _saveDirectoryGrants(plugin, directoryGrants);
    }
    if ((outsideSandbox ||
            commandPattern != null ||
            decision != ApprovalDecision.allowAlways) &&
        {
          ApprovalDecision.allowAlways,
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal
        }.contains(decision)) {
      if (!review.isActive()) return Approval.no;
      if (readerDigest != null && commandPattern == null) {
        if (sha256
                .convert(File(readerCandidate!).readAsBytesSync())
                .toString() !=
            readerDigest) return Approval.no;
        plugin.commandApprovals.rememberReader(
            readerCandidate,
            readerDigest,
            switch (decision) {
              ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
              ApprovalDecision.allowGlobal => CommandApprovalScope.global,
              _ => CommandApprovalScope.session,
            });
        return Approval.yes;
      }
      plugin.commandApprovals.remember(
          request,
          review.missingPermissions,
          switch (decision) {
            ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
            ApprovalDecision.allowGlobal => CommandApprovalScope.global,
            _ => CommandApprovalScope.session,
          },
          pattern: commandPattern,
          workflow: !outsideSandbox && !network && commandPattern == null,
          directoryAccess: review.directoryAccess);
      return Approval.yes;
    }
    if ((decision == ApprovalDecision.allowReadsInDirectory ||
            decision == ApprovalDecision.allowAlwaysAndReadsInDirectory) &&
        review.readDirectory != null &&
        plugin.osPlan.canGrant(review.readDirectory!)) {
      plugin.rememberReadDirectory(review.readDirectory!);
    }
    if (decision == ApprovalDecision.allowReadsAlways) {
      if (network ||
          outsideSandbox ||
          review.directoryAccess.read.isEmpty ||
          review.directoryAccess.write.isNotEmpty ||
          review.missingPermissions.any(
              (permission) => permission != ProcessPermission.directoryAccess))
        return Approval.no;
      // The dialog only offers this for all-read asks, and the grants were
      // validated against those offers above; the scope rides the grants.
      // A channel that answers without grants defaults to session scope —
      // the narrowest standing read grant this answer can mean.
      final scopes = directoryGrants.map((grant) => grant.scope).toSet();
      final scope = switch (scopes.length) {
        1 => scopes.single,
        _ => DirectoryGrantScope.session,
      };
      if (settings != null) {
        settings.set(allowReadsOutsideWorkspaceSetting, true,
            SettingScope.values.byName(scope.name));
      }
      // Without persistent settings the standing grant cannot be remembered;
      // the answer still approves this invocation, exactly like 'allow'.
      return Approval.yes;
    }
    return switch (decision) {
      ApprovalDecision.allow => Approval.yes,
      // Handled above; the arm keeps the switch total if that block moves.
      ApprovalDecision.allowReadsAlways => Approval.yes,
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
