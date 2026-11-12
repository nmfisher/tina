import 'dart:convert';
import 'package:path/path.dart' as p;
import 'command_approval_store.dart';
import 'path_grants.dart';

/// Current grants shown in Settings: paths, token prefixes and MCP access.
/// Explicit MCP access entries retain their existing store and revocation UI.
final class ResourceApprovalStore extends CommandApprovalStore {
  ResourceApprovalStore(
      {required super.workspace,
      required this.paths,
      super.file,
      super.searchPath});
  final PathGrants paths;

  @override
  List<Map<String, Object?>> get entries => [
        ...super.entries.where((e) =>
            e['kind'] == 'command_prefix' ||
            e['kind'] == 'access' &&
                (!{'read', 'write', 'delete', 'execute'}
                        .contains(e['capability']) ||
                    e['target'] is String &&
                        !p.isAbsolute(e['target'] as String))),
        for (final grant in paths.grants)
          {
            'id':
                'path:${grant.write}:${grant.recursive}:${base64Url.encode(utf8.encode(grant.path))}',
            'kind': 'path',
            'scope': 'workspace',
            'decided_by': 'user',
            'command':
                '${grant.write ? 'Read/write' : 'Read'} ${grant.recursive ? 'directory' : 'file'}',
            'directory': grant.path,
            'target': grant.path,
            'capability': grant.write ? 'write' : 'read',
          },
      ];

  @override
  bool coversAccess(String capability, String target) =>
      p.isAbsolute(target) && (capability == 'read' || capability == 'write')
          ? paths.allows(target, write: capability == 'write')
          : super.coversAccess(capability, target);

  @override
  void revoke(String id, {String? directory}) {
    if (!id.startsWith('path:')) return super.revoke(id, directory: directory);
    final parts = id.split(':');
    if (parts.length != 4) throw const FormatException('Invalid path grant id');
    paths.revoke(utf8.decode(base64Url.decode(parts[3])),
        write: parts[1] == 'true', recursive: parts[2] == 'true');
  }
}
