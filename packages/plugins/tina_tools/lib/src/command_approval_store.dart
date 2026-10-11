import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tina_approvals/tina_approvals.dart' show CommandApprovalPattern;

import 'process_runner.dart';
import 'sandbox_home.dart';

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
      {bool patterned = false}) {
    final keys = request.environment?.keys.toList()?..sort();
    return sha256
        .convert(utf8.encode(jsonEncode([
          _executable(request),
          patterned
              ? (_shellString(request) ? 'shell -c' : 'quoted argv')
              : request.arguments,
          if (scope != CommandApprovalScope.global)
            canonicalSandboxPath(request.workingDirectory ?? workspace),
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

  bool covers(ProcessRequest request, Set<ProcessPermission> permissions) {
    try {
      return entries.any((entry) {
        final scope =
            CommandApprovalScope.values.byName(entry['scope'] as String);
        final granted = (entry['permissions'] as List).cast<String>().toSet();
        final pattern = entry['pattern'];
        return entry['identity'] ==
                _identity(request, scope, patterned: pattern != null) &&
            (pattern == null ||
                pattern is String &&
                    CommandApprovalPattern(pattern)
                        .matches(approvalCommandText(request))) &&
            permissions
                .every((permission) => granted.contains(permission.name));
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
      {String? pattern}) {
    if (pattern != null) {
      CommandApprovalPattern(pattern)
          .requireMatch(approvalCommandText(request));
    }
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
      'identity': _identity(request, scope, patterned: pattern != null),
      'command': approvalCommandText(request),
      if (pattern != null) 'pattern': pattern,
      'directory': scope == CommandApprovalScope.global
          ? 'any directory'
          : canonicalSandboxPath(request.workingDirectory ?? workspace),
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

  void revoke(String id) {
    _session.removeWhere((entry) => entry['id'] == id);
    if (file?.existsSync() == true)
      _update((entries) => entries.removeWhere((entry) => entry['id'] == id));
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
