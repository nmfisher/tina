import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tina_approvals/tina_approvals.dart' show CommandApprovalPattern;

import 'process_runner.dart';
import 'sandbox_home.dart';
import 'command_workflow.dart';
import 'read_only_commands.dart';

enum CommandApprovalScope { session, workspace, global }

bool _shellString(ProcessRequest request) =>
    {'sh', 'bash', 'zsh', 'dash', 'ksh'}
        .contains(p.basename(request.command)) &&
    request.arguments.length == 2 &&
    request.arguments.first == '-c';

/// Shell tools expose their script; exec tools expose unambiguous quoted argv.
/// Joining argv without quoting would confuse ['a b'] with ['a', 'b'].
String approvalCommandText(ProcessRequest request) {
  if (_shellString(request)) return request.arguments[1];
  String quote(String value) => RegExp(r'^[a-zA-Z0-9_./:=+-]+$').hasMatch(value)
      ? value
      : "'${value.replaceAll("'", "'\\''")}'";
  return [request.command, ...request.arguments].map(quote).join(' ');
}

/// Resolve before asking, then spawn this same absolute executable. Relative
/// PATH entries are interpreted against the command's working directory.
String resolveHostExecutable(ProcessRequest request,
    {required String workspace, String? searchPath}) {
  final cwd = request.workingDirectory ?? workspace;
  if (request.command.contains('/')) {
    final target = canonicalSandboxPath(p.isAbsolute(request.command)
        ? request.command
        : p.join(cwd, request.command));
    if (File(target).existsSync()) return target;
  } else {
    for (final dir in (searchPath ?? '/usr/bin:/bin').split(':')) {
      final candidate = File(
          p.join(p.isAbsolute(dir) ? dir : p.join(cwd, dir), request.command));
      if (candidate.existsSync() &&
          (Platform.isWindows || candidate.statSync().mode & 0x49 != 0)) {
        return candidate.resolveSymbolicLinksSync();
      }
    }
  }
  throw FileSystemException(
      'Cannot resolve approval executable', request.command);
}

/// Human decisions only. Never loaded from a repository's settings. Every
/// lookup rereads disk, so revocation takes effect in other running sessions.
final class CommandApprovalStore {
  CommandApprovalStore({required this.workspace, this.file, this.searchPath});
  final String workspace;
  final File? file;
  final String? searchPath;
  final List<Map<String, Object?>> _session = [];

  String _executable(ProcessRequest request) => resolveHostExecutable(request,
      workspace: workspace, searchPath: searchPath);

  String _identity(ProcessRequest request, CommandApprovalScope scope,
      {bool patterned = false, String? workflow}) {
    final keys = request.environment?.keys.toList()?..sort();
    return sha256
        .convert(utf8.encode(jsonEncode([
          _executable(workflow == null
              ? request
              : literalShellRequest(request) ?? request),
          workflow ??
              (patterned
                  ? (_shellString(request) ? 'shell -c' : 'quoted argv')
                  : request.arguments),
          if (scope != CommandApprovalScope.global)
            canonicalSandboxPath(workflow == null
                ? request.workingDirectory ?? workspace
                : workspace),
          if (keys == null)
            null
          else
            {for (final k in keys) k: request.environment![k]},
          request.stdin,
        ])))
        .toString();
  }

  List<Map<String, Object?>> _read() {
    if (file == null || !file!.existsSync()) return [];
    final document = jsonDecode(file!.readAsStringSync());
    if (document is! Map ||
        document['version'] != 1 ||
        document['grants'] is! List) {
      throw const FormatException('Invalid command approval store');
    }
    return (document['grants'] as List)
        .map((v) => Map<String, Object?>.from(v as Map))
        .toList();
  }

  List<Map<String, Object?>> get entries => List.unmodifiable([
        ..._session,
        ..._read(),
      ].where((v) =>
          v['scope'] == 'global' ||
          v['workspace'] == canonicalSandboxPath(workspace)));

  Map<String, Object?> settings(CommandApprovalScope scope) => {
        for (final entry in entries)
          if (entry['kind'] == 'setting' && entry['scope'] == scope.name)
            entry['setting'] as String: entry['value'],
      };

  void replaceSettings(CommandApprovalScope scope, Map<String, Object?> values,
      {Map<String, Object?>? expected}) {
    void change(List<Map<String, Object?>> entries) {
      final current = {
        for (final entry in entries)
          if (entry['kind'] == 'setting' &&
              entry['scope'] == scope.name &&
              (scope == CommandApprovalScope.global ||
                  entry['workspace'] == canonicalSandboxPath(workspace)))
            entry['setting'] as String: entry['value'],
      };
      if (expected != null && jsonEncode(current) != jsonEncode(expected))
        throw StateError('Permission settings changed; reload and try again');
      entries.removeWhere((entry) =>
          entry['kind'] == 'setting' &&
          entry['scope'] == scope.name &&
          (scope == CommandApprovalScope.global ||
              entry['workspace'] == canonicalSandboxPath(workspace)));
      for (final entry in values.entries) {
        entries.add({
          'kind': 'setting',
          'id': 'setting:${scope.name}:$workspace:${entry.key}',
          'scope': scope.name,
          if (scope != CommandApprovalScope.global)
            'workspace': canonicalSandboxPath(workspace),
          'setting': entry.key,
          'value': entry.value,
          'command': entry.key.split('/').last.replaceAll('_', ' '),
          'directory': entry.value is List
              ? (entry.value as List).join(', ')
              : entry.value.toString(),
        });
      }
    }

    if (scope == CommandApprovalScope.session) {
      change(_session);
    } else {
      if (file == null)
        throw StateError('Persistent approval storage is unavailable');
      _update(change);
    }
  }

  Map<String, String> get readerExecutables {
    try {
      return {
        for (final entry in entries)
          if (entry['kind'] == 'reader' &&
              entry['executable'] is String &&
              entry['digest'] is String)
            entry['executable'] as String: entry['digest'] as String,
      };
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    } on TypeError {
      return {};
    }
  }

  void rememberReader(
      String executable, String digest, CommandApprovalScope scope) {
    final entry = <String, Object?>{
      'kind': 'reader',
      'id': 'reader:${scope.name}:$workspace:$executable:$digest',
      'scope': scope.name,
      if (scope != CommandApprovalScope.global)
        'workspace': canonicalSandboxPath(workspace),
      'executable': executable,
      'digest': digest,
      'command': 'Permitted reads with $executable (supported options only)',
      'directory':
          scope == CommandApprovalScope.global ? 'all workspaces' : workspace,
    };
    if (scope == CommandApprovalScope.session) {
      _session.add(entry);
    } else {
      if (file == null)
        throw StateError('Persistent approval storage is unavailable');
      _update((entries) => entries.add(entry));
    }
  }

  /// File and MCP access use the same scope, storage and revocation lifecycle.
  bool coversAccess(String capability, String target) {
    try {
      return entries.any((entry) =>
          entry['kind'] == 'access' &&
          (entry['capability'] == capability ||
              capability == 'read' && entry['capability'] == 'write') &&
          entry['target'] == target);
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  void rememberAccess(
      String capability, String target, CommandApprovalScope scope) {
    final entry = <String, Object?>{
      'kind': 'access',
      'id': 'access:${scope.name}:$workspace:$capability:$target',
      'scope': scope.name,
      if (scope != CommandApprovalScope.global)
        'workspace': canonicalSandboxPath(workspace),
      'capability': capability,
      'target': target,
      'command': '$capability $target',
      'directory': workspace,
    };
    if (scope == CommandApprovalScope.session) {
      _session.removeWhere((value) => value['id'] == entry['id']);
      _session.add(entry);
    } else {
      if (file == null)
        throw StateError('Persistent approval storage is unavailable');
      _update((entries) {
        entries.removeWhere((value) => value['id'] == entry['id']);
        entries.add(entry);
      });
    }
  }

  bool covers(ProcessRequest request, Set<ProcessPermission> permissions,
      {ProcessDirectoryAccess directoryAccess =
          const ProcessDirectoryAccess.empty()}) {
    try {
      return entries.where((entry) => entry['kind'] == null).any((entry) {
        final scope =
            CommandApprovalScope.values.byName(entry['scope'] as String);
        final granted = (entry['permissions'] as List).cast<String>().toSet();
        final pattern = entry['pattern'];
        final workflow = entry['workflow'] as String?;
        return entry['identity'] ==
                _identity(request, scope,
                    patterned: pattern != null, workflow: workflow) &&
            (workflow == null ||
                commandWorkflow(request, workspace) == workflow) &&
            (pattern == null ||
                pattern is String &&
                    CommandApprovalPattern(pattern)
                        .matches(approvalCommandText(request))) &&
            permissions.every((permission) =>
                granted.contains(permission.name) ||
                permission == ProcessPermission.workspaceWrite &&
                    (granted.contains(ProcessPermission.unconfined.name) ||
                        entry['profile_version'] == null &&
                            granted
                                .contains(ProcessPermission.execution.name))) &&
            ProcessDirectoryAccess.fromJson(entry['directory_access'])
                .covers(directoryAccess);
      });
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    } on TypeError {
      return false;
    }
  }

  void remember(ProcessRequest request, Set<ProcessPermission> permissions,
      CommandApprovalScope scope,
      {String? pattern,
      bool workflow = false,
      ProcessDirectoryAccess directoryAccess =
          const ProcessDirectoryAccess.empty()}) {
    if (pattern != null) {
      CommandApprovalPattern(pattern)
          .requireMatch(approvalCommandText(request));
    }
    final family = workflow &&
            pattern == null &&
            scope != CommandApprovalScope.session &&
            !permissions.contains(ProcessPermission.network) &&
            !permissions.contains(ProcessPermission.unconfined)
        ? commandWorkflow(request, workspace)
        : null;
    final entry = <String, Object?>{
      'id': List.generate(
          16,
          (_) => Random.secure()
              .nextInt(256)
              .toRadixString(16)
              .padLeft(2, '0')).join(),
      'scope': scope.name,
      if (scope != CommandApprovalScope.global)
        'workspace': canonicalSandboxPath(workspace),
      'profile_version': 2,
      'identity': _identity(request, scope,
          patterned: pattern != null, workflow: family),
      'command':
          family == null ? approvalCommandText(request) : '$family (workflow)',
      'executable': _executable(request),
      if (!directoryAccess.isEmpty)
        'directory_access': directoryAccess.toJson(),
      if (pattern != null) 'pattern': pattern,
      if (family != null) 'workflow': family,
      'directory': scope == CommandApprovalScope.global
          ? 'any directory'
          : family == null
              ? canonicalSandboxPath(request.workingDirectory ?? workspace)
              : '${canonicalSandboxPath(workspace)} (including subdirectories)',
      'permissions': permissions.map((p) => p.name).toList(),
    };
    if (scope == CommandApprovalScope.session) {
      _session.add(entry);
    } else {
      if (file == null)
        throw StateError('Persistent approval storage is unavailable');
      _update((entries) => entries.add(entry));
    }
  }

  void revoke(String id, {String? directory}) {
    _session.removeWhere((entry) => entry['id'] == id);
    if (file?.existsSync() == true)
      _update((entries) {
        for (final entry in entries) {
          if (entry['id'] == id && entry['kind'] == 'setting') {
            entry['value'] = entry['value'] is List
                ? directory == null
                    ? <String>[]
                    : (entry['value'] as List)
                        .where((value) => value != directory)
                        .toList()
                : false;
            return;
          }
        }
        entries.removeWhere((entry) => entry['id'] == id);
      });
  }

  /// Diagnostic only: a related rule exists but did not cover this request.
  bool hasRelatedRule(ProcessRequest request) {
    try {
      final executable = _executable(request);
      return entries.where((entry) => entry['kind'] == null).any((entry) =>
          entry['executable'] == executable ||
          entry['command'] == approvalCommandText(request));
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  void _update(void Function(List<Map<String, Object?>>) change) {
    final target = file!;
    target.parent.createSync(recursive: true);
    if (!Platform.isWindows &&
        Process.runSync('/bin/chmod', ['700', target.parent.path]).exitCode !=
            0) {
      throw FileSystemException(
          'Cannot protect approval directory', target.parent.path);
    }
    final lock = File('${target.path}.lock').openSync(mode: FileMode.append);
    Directory? staging;
    try {
      lock.lockSync(FileLock.blockingExclusive);
      final entries = _read();
      change(entries);
      staging = target.parent.createTempSync('.approvals-');
      final next = File(p.join(staging.path, 'grants'));
      next.writeAsStringSync(jsonEncode({'version': 1, 'grants': entries}),
          flush: true);
      if (!Platform.isWindows) {
        final result = Process.runSync('/bin/chmod', ['600', next.path]);
        if (result.exitCode != 0)
          throw FileSystemException('Cannot protect approval store', next.path);
      }
      next.renameSync(target.path);
    } finally {
      lock.closeSync();
      staging?.deleteSync(recursive: true);
    }
  }
}
