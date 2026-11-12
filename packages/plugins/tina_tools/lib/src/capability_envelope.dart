/// The capability envelope: what a command touches, parsed once.
///
/// Layer 1 of the permission restructure. Every permission check consumes
/// this one component instead of parsing the command again. The envelope
/// carries:
///
/// - the paths the command reads and writes,
/// - whether the command wants the network,
/// - which executables it runs and where they came from,
/// - whether the whole pipeline is a certified reader,
/// - whether the command is destructive.
///
/// The quote-aware parser and the certified-reader tables
/// (read_only_commands.dart) are internal to this component. Callers ask
/// the envelope; they never read the tables. Parsing is pure: the same
/// request and tables always produce the same envelope. The envelope
/// grants nothing by itself. The decision pipeline
/// (sandboxed_process_runner.dart) compares it against approved scopes
/// and sandbox feasibility.
library;

import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:tina_mode/tina_mode.dart'
    show PermissionAccess, PermissionAccessOperation;
import 'process_runner.dart';
import 'read_only_commands.dart';

/// Where an executed component came from.
enum CapabilityProvenance {
  /// Absolute path given as-is.
  absolute,

  /// Resolved through the executable search path.
  searchPath,

  /// Named but unresolved (unknown command or shell payload).
  named,
}

/// One executable the command would run.
final class CapabilityExecution {
  const CapabilityExecution(this.executable, this.provenance);

  /// The component as resolved: an absolute path when known, else the word.
  final String executable;

  /// How [executable] was determined.
  final CapabilityProvenance provenance;

  @override
  String toString() => '$executable (${provenance.name})';
}

/// What a command touches. The envelope is computed once per check and
/// compared everywhere afterwards.
///
/// [reads] and [writes] list the paths the parse identified: report
/// operands for certified readers, plus directories declared through the
/// request's control. These are facts, not grants. The decision pipeline
/// checks whether the paths sit inside approved scopes and whether the
/// sandbox can hold them there.
final class CapabilityEnvelope {
  CapabilityEnvelope._({
    required this.literalRequest,
    required this.readerRequest,
    required this.shellReader,
    required this.reader,
    required this.firstComponentResolved,
    required this.certifiedArguments,
    required this.verifiedAccesses,
    required this.completeVerifiedAccesses,
    required this.declaredReads,
    required this.declaredWrites,
    required this.network,
    required this.executions,
    required this.destructiveBecause,
  });

  /// The quote-aware literal parse of a shell-string request, or null when
  /// the request is not a shell payload (or not literally parseable).
  final ProcessRequest? literalRequest;

  /// The request the certified-reader tables examine: the literal parse
  /// when one exists, else the request itself.
  final ProcessRequest readerRequest;

  /// The pinned certified pipeline for a shell-string request, or null when
  /// the payload is not a fully certified reader script.
  final ProcessRequest? shellReader;

  /// The resolved trusted reader executable for a single command request,
  /// or null when the command is not a certified reader.
  final String? reader;

  /// The first component, resolved, whether or not it is a trusted reader.
  /// This is the digest input when reviewing a reader candidate that is
  /// not trusted yet.
  final String? firstComponentResolved;

  /// The argv a certified single reader runs (pinned executable, literal
  /// arguments). Empty unless [reader] is set.
  final List<String> certifiedArguments;

  /// The filesystem effects the certified parse identified. Empty when the
  /// command is not certified. An unknown command has no verified accesses.
  final List<PermissionAccess> verifiedAccesses;

  /// Whether the certified parse identified every effect completely.
  /// Unknown commands are never complete.
  final bool completeVerifiedAccesses;

  /// Read directories declared for this invocation through the control.
  final List<String> declaredReads;

  /// Write directories declared for this invocation through the control.
  final List<String> declaredWrites;

  /// Whether the command's subprocess tree asks for the network.
  final bool network;

  /// The executables this command would run, in order. A certified reader
  /// pins its resolved pipeline. Otherwise this lists the request's
  /// components as far as they resolve. A shell's payload stays named: its
  /// internals are what certification would pin.
  final List<CapabilityExecution> executions;

  /// Non-null when the command is destructive by table (irreversible
  /// delete/format utilities, force-push flags, device-writing dd). The
  /// string names the reason. It feeds refusal messages and end-of-turn
  /// batching. A destructive command is never run silently.
  final String? destructiveBecause;

  /// Certified reader end to end: single trusted reader or pinned script.
  bool get certifiedReadOnly => reader != null || shellReader != null;

  /// True when the parse marks the command destructive.
  bool get destructive => destructiveBecause != null;

  /// Paths the command reads: verified report operands plus declared read
  /// directories.
  List<String> get reads => [
        for (final access in verifiedAccesses)
          if (access.operation == PermissionAccessOperation.read) access.path,
        ...declaredReads,
      ];

  /// Arguments that name paths (absolute or containing separators). For an
  /// uncertified command these are the only touchable paths the parse can
  /// see; the fast path checks them against approved scopes.
  late final List<String> argumentPaths = List.unmodifiable([
    for (final argument in readerRequest.arguments)
      if (argument.startsWith('/') || argument.contains('/')) argument,
  ]);

  /// Paths the command writes, creates, deletes or moves: verified
  /// write-classified operands plus declared write directories.
  List<String> get writes => [
        for (final access in verifiedAccesses)
          if (access.operation != PermissionAccessOperation.read) access.path,
        ...declaredWrites,
      ];

  /// The read directory a certified single-file reader reports, for the
  /// remember-reads dialog (read_only_commands' helper over this parse).
  String? readDirectory(String? workspaceRoot) =>
      readDirectoryForRequest(readerRequest, workspaceRoot);

  /// Parse [request] once. Pure: the same request and tables produce the
  /// same envelope. [control] contributes declared directory access and the
  /// network request — the envelope reports them, it does not judge them.
  static CapabilityEnvelope parse(
    ProcessRequest request, {
    ProcessControl? control,
    String? searchPath,
    Map<String, String> trustedExecutables = const {},
    bool Function(String executable)? canWrite,
    bool filteredEnvironment = false,
  }) {
    // The gate freezes the sandbox's ordinary environment before review.
    // That snapshot is not a custom tool environment. Reader certification
    // still rejects extra variables that could change command behavior.
    if (filteredEnvironment &&
        request.environment != null &&
        request.environment!.keys
            .every({'PATH', 'HOME', 'TMPDIR', 'LANG'}.contains)) {
      request = (
        command: request.command,
        arguments: request.arguments,
        workingDirectory: request.workingDirectory,
        environment: null,
        stdin: request.stdin,
        timeout: request.timeout
      );
    }
    final literal = literalShellRequest(request);
    final readerRequest = literal ?? request;
    final shellReader = readOnlyShellRequest(request,
        searchPath: searchPath,
        trustedExecutables: trustedExecutables,
        canWrite: canWrite ?? writesNothing);
    final reader = readOnlyExecutable(readerRequest,
        searchPath: searchPath, trustedExecutables: trustedExecutables);
    final accesses = verifiedReaderAccesses(request,
        searchPath: searchPath, trustedExecutables: trustedExecutables);
    return CapabilityEnvelope._(
      literalRequest: literal,
      readerRequest: readerRequest,
      shellReader: shellReader,
      reader: reader,
      firstComponentResolved: readOnlyExecutable(readerRequest,
          searchPath: searchPath, candidateOnly: true),
      certifiedArguments:
          reader != null ? certifiedReaderArguments(readerRequest) : const [],
      verifiedAccesses: accesses,
      completeVerifiedAccesses: reader != null || shellReader != null
          ? hasCompleteReaderAccesses(request,
              searchPath: searchPath, trustedExecutables: trustedExecutables)
          : false,
      declaredReads: List.unmodifiable(control?.readDirectories ?? const []),
      declaredWrites: List.unmodifiable(control?.writeDirectories ?? const []),
      network: control?.networkRequested ?? false,
      executions:
          _executions(readerRequest, searchPath: searchPath, reader: reader),
      destructiveBecause: _destructiveBecause(readerRequest, reader: reader),
    );
  }

  static bool writesNothing(String executable) => false;

  static List<CapabilityExecution> _executions(ProcessRequest request,
      {String? searchPath, required String? reader}) {
    if (reader != null) {
      return [CapabilityExecution(reader, CapabilityProvenance.absolute)];
    }
    String? resolve(String word) {
      if (path.isAbsolute(word)) return word;
      if (word.contains(path.separator)) return null;
      for (final dir in (searchPath ?? '').split(':')) {
        if (dir.isEmpty) continue;
        final candidate = path.join(dir, word);
        if (File(candidate).existsSync()) return candidate;
      }
      return null;
    }

    final out = <CapabilityExecution>[];
    for (final word in [request.command, ...request.arguments]) {
      if (word.startsWith('-')) continue;
      final resolved = resolve(word);
      if (resolved == null) {
        if (word == request.command) {
          out.add(CapabilityExecution(word, CapabilityProvenance.named));
        }
        continue;
      }
      out.add(CapabilityExecution(
          resolved,
          path.isAbsolute(word)
              ? CapabilityProvenance.absolute
              : CapabilityProvenance.searchPath));
      if (out.length >= 8) break; // bounded: provenance, not enumeration
    }
    return out;
  }

  /// The destructive table: irreversible utilities and force flags. The
  /// list is deliberately conservative. A destructive verdict always goes
  /// to judgment; the command is never run silently. Certified readers
  /// never appear here.
  static const _destructiveUtilities = {
    'rm': 'removes files or directories',
    'rmdir': 'removes directories',
    'shred': 'irreversibly overwrites files',
    'unlink': 'removes a file',
    'truncate': 'truncates files to zero',
    'mkfs': 'creates a filesystem, destroying the target',
    'wipefs': 'wipes filesystem signatures',
    'fdisk': 'partitions a device, destroying its contents',
    'parted': 'partitions a device, destroying its contents',
    'git-clean': 'removes untracked files',
  };

  /// The destructive-table verdict for one component (program + arguments),
  /// public so other gates (the box sorter) can apply the same table to
  /// every pipeline component. Destructive commands are never run silently
  /// by any path.
  static String? componentDestructiveBecause(
          String program, List<String> arguments) =>
      _destructiveBecause((
        command: program,
        arguments: arguments,
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ), reader: null);

  static String? _destructiveBecause(ProcessRequest request,
      {required String? reader}) {
    if (reader != null) return null; // A pinned single reader never deletes.
    final basename = path.basename(request.command);
    if (_destructiveUtilities.containsKey(basename)) {
      return '${_destructiveUtilities[basename]} ($basename)';
    }
    if (basename == 'dd') {
      for (final argument in request.arguments) {
        if (argument.startsWith('of=/dev/')) {
          return 'writes a raw device (dd of=/dev/…)';
        }
      }
    }
    if (basename == 'git') {
      final arguments = request.arguments;
      if (arguments.isNotEmpty && arguments.first == 'push') {
        for (final argument in arguments.skip(1)) {
          if (argument == '-f' ||
              argument == '--force' ||
              argument.startsWith('--force')) {
            return 'force-pushes refs (git push --force)';
          }
        }
      }
      if (arguments.isNotEmpty &&
          arguments.first == 'clean' &&
          !arguments
              .any((argument) => argument == '-n' || argument == '--dry-run')) {
        return 'removes untracked files (git clean)';
      }
    }
    return null;
  }
}
