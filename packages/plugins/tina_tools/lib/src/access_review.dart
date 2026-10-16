import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_mode/tina_mode.dart';
import 'os_sandbox_runner.dart';
import 'sandbox_home.dart';

/// Resolve inferred operands against the actual command cwd. Only an existing,
/// explicit directory or a file's immediate parent may become an offered grant.
/// No wider ancestor is derived from a missing target, credentials remain protected, and
/// returned assessments never change the execution gate.
Map<String, Object?> permissionAccessReview({
  required SandboxPlan plan,
  required String cwd,
  required List<PermissionAccess> verified,
  required PermissionJudgment judgment,
  bool complete = false,
  bool persistent = true,
}) {
  final accesses = <Map<String, Object?>>[];
  final seen = <String>{};
  void add(PermissionAccess access, String source) {
    if (access.path.trim().isEmpty ||
        access.path.length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(access.path)) return;
    final String target;
    try {
      target = canonicalSandboxPath(
          p.isAbsolute(access.path) ? access.path : p.join(cwd, access.path));
    } on FileSystemException {
      return;
    }
    if (!seen.add('${access.operation.name}:$target')) return;
    accesses.add({...access.toJson(), 'path': target, 'source': source});
  }

  for (final access in verified) {
    add(access, 'verified');
  }
  // An exact file-tool report already describes its logical operation. Model
  // guesses cannot turn internal temp renames/deletions into requested effects.
  if (!complete) {
    for (final access in judgment.assessment.accesses) {
      add(access, 'inferred');
    }
  }
  final offers = <Map<String, Object?>>[];
  final offered = <String>{};
  for (final access in accesses) {
    final target = access['path'] as String;
    if (RegExp(r'[*?\[\]$`{}]').hasMatch(target) || plan.isProtected(target))
      continue;
    final isDirectory = Directory(target).existsSync();
    final kind = access['target_kind'];
    if (kind == 'unknown' || kind == 'directory' && !isDirectory) continue;
    final directory = isDirectory ? target : p.dirname(target);
    if (!Directory(directory).existsSync() ||
        directory == p.separator ||
        plan.hostHome != null &&
            p.equals(directory, canonicalSandboxPath(plan.hostHome!)) ||
        (access['source'] == 'inferred' || access['operation'] == 'read') &&
            (p.equals(directory, canonicalSandboxPath(plan.workspaceRoot)) ||
                p.isWithin(
                    canonicalSandboxPath(plan.workspaceRoot), directory)))
      continue;
    final write = access['operation'] != 'read';
    if (!plan.canGrant(directory, write: write)) continue;
    final operation = write ? 'write' : 'read';
    if (offered.add('$operation:$directory')) {
      offers.add(
          {'path': directory, 'access': operation, 'source': access['source']});
    }
  }
  return {
    'accesses': accesses,
    'access_coverage':
        complete ? 'complete' : judgment.assessment.coverage.name,
    'access_coverage_source': complete ? 'verified' : 'inferred',
    'unresolved_accesses':
        complete ? const <String>[] : judgment.assessment.unresolved,
    'directory_accesses': offers,
    'directory_grant_scopes':
        persistent ? ['session', 'workspace', 'global'] : ['session'],
  };
}

bool validateDirectoryGrants(SandboxPlan plan,
    List<DirectoryAccessGrant> grants, Map<String, Object?> details) {
  if (grants.isEmpty) return true;
  final offers = details['directory_accesses'];
  final scopes = details['directory_grant_scopes'];
  if (grants.length > 32 ||
      grants.map((grant) => grant.scope).toSet().length != 1 ||
      offers is! List ||
      scopes is! List) return false;
  try {
    return grants.every((grant) =>
        scopes.contains(grant.scope.name) &&
        offers.any((offer) =>
            offer is Map &&
            offer['path'] == grant.path &&
            offer['access'] == grant.access.name) &&
        p.isAbsolute(grant.path) &&
        Directory(grant.path).existsSync() &&
        p.equals(
            grant.path, Directory(grant.path).resolveSymbolicLinksSync()) &&
        grant.path != p.separator &&
        (plan.hostHome == null ||
            !p.equals(grant.path, canonicalSandboxPath(plan.hostHome!))) &&
        plan.canGrant(grant.path,
            write: grant.access == DirectoryAccess.write));
  } on FileSystemException {
    return false;
  }
}
