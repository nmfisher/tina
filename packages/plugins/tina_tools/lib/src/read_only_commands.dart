import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';

import 'process_runner.dart';
import 'read_directories.dart';
import 'sandbox_home.dart';
import 'package:tina_mode/tina_mode.dart'
    show PermissionAccess, PermissionAccessOperation, PermissionTargetKind;

typedef _ShellPart = ({
  List<String> words,
  String? operator,
  List<({String text, String? target})> redirects
});

({String text, String target, int end})? _fileRedirectAt(
    String script, int start) {
  var cursor = start;
  while (cursor < script.length && RegExp(r'[0-9]').hasMatch(script[cursor]))
    cursor++;
  if (cursor >= script.length || script[cursor] != '>') return null;
  cursor++;
  if (cursor < script.length && script[cursor] == '>') cursor++;
  final operator = script.substring(start, cursor);
  while (cursor < script.length && RegExp(r'[ \t]').hasMatch(script[cursor]))
    cursor++;
  final word = StringBuffer();
  String? quote;
  for (; cursor < script.length; cursor++) {
    final character = script[cursor];
    if (quote == "'") {
      if (character == "'")
        quote = null;
      else
        word.write(character);
    } else if (character == '\\') {
      if (++cursor >= script.length) return null;
      if (quote == '"' && !'"\u0024`\\'.contains(script[cursor]))
        word.write('\\');
      word.write(script[cursor]);
    } else if (quote == '"') {
      if (character == '"')
        quote = null;
      else if ('\u0024`'.contains(character))
        return null;
      else
        word.write(character);
    } else if (character == "'" || character == '"') {
      quote = character;
    } else if (RegExp(r'\s').hasMatch(character) || '|;&'.contains(character)) {
      break;
    } else if ('\u0024`<>()[*?~#{}'.contains(character) ||
        character.codeUnitAt(0) < 32) {
      return null;
    } else {
      word.write(character);
    }
  }
  if (quote != null || word.isEmpty) return null;
  final target = word.toString();
  return (
    text: "$operator '${target.replaceAll("'", "'\\''")}'",
    target: target,
    end: cursor
  );
}

/// Output-only redirections, kept verbatim in the reconstructed script.
/// Each writes to the null device or duplicates an already-open descriptor:
/// no path is read, created or modified, so certification is unaffected.
const _outputRedirects = {
  '2>/dev/null',
  '2>>/dev/null',
  '>/dev/null',
  '>>/dev/null',
  '1>/dev/null',
  '1>>/dev/null',
  '&>/dev/null',
  '2>&1',
  '1>&2',
  '2>>&1',
};

/// Longest redirect a script suffix can start with, or null. Word boundaries
/// matter: `2>&1x` is not `2>&1`, and `2>/dev/nullx` is not `/dev/null`.
String? _redirectAt(String script, int start) {
  for (final token in _outputRedirects) {
    final end = start + token.length;
    if (script.startsWith(token, start) &&
        (end >= script.length ||
            !RegExp(r'[A-Za-z0-9_=/&>-]').hasMatch(script[end]))) {
      return token;
    }
  }
  return null;
}

/// A deliberately small shell grammar: literal arguments and |, ; or &&,
/// plus output-only redirects. The accepted words are re-quoted before
/// execution, never reused as script.
List<_ShellPart>? _literalShellParts(ProcessRequest request) {
  if (request.command != '/bin/sh' ||
      request.arguments.length != 2 ||
      request.arguments.first != '-c') return null;
  final script = request.arguments.last;
  if (script.contains('\n') || script.contains('\r')) return null;
  var words = <String>[];
  final parts = <_ShellPart>[];
  final redirects = <({String text, String? target})>[];
  var word = StringBuffer();
  String? quote;
  var active = false;
  for (var i = 0; i < script.length; i++) {
    final char = script[i];
    if (quote == "'") {
      if (char == "'") {
        quote = null;
      } else {
        word.write(char);
      }
    } else if (char == '\\') {
      if (++i >= script.length) return null;
      final escaped = script[i];
      // POSIX double quotes preserve a backslash before other characters,
      // including the \| in a basic grep expression.
      if (quote == '"' && !'"\u0024`\\'.contains(escaped)) word.write('\\');
      word.write(escaped);
      active = true;
    } else if (quote == '"') {
      if (char == '"') {
        quote = null;
      } else if ('\u0024`'.contains(char)) {
        return null;
      } else {
        word.write(char);
      }
    } else if (char == "'" || char == '"') {
      quote = char;
      active = true;
    } else if (RegExp(r'\s').hasMatch(char)) {
      if (active) {
        words.add(word.toString());
        word = StringBuffer();
        active = false;
      }
      // An output-only redirect may follow this whitespace; consuming it
      // here keeps its fd/dup characters out of the word parser entirely.
      var end = i;
      while (
          end + 1 < script.length && RegExp(r'\s').hasMatch(script[end + 1])) {
        end++;
      }
      final redirect = _redirectAt(script, end + 1);
      if (redirect != null) {
        redirects.add((text: redirect, target: null));
        i = end + redirect.length;
        continue;
      }
      final output = _fileRedirectAt(script, end + 1);
      if (output != null) {
        redirects.add((text: output.text, target: output.target));
        i = output.end - 1;
        continue;
      }
    } else if ('|;&'.contains(char)) {
      if (active) words.add(word.toString());
      word = StringBuffer();
      active = false;
      if (words.isEmpty || words.first.isEmpty) return null;
      var operator = char;
      if (char == '&') {
        if (i + 1 >= script.length || script[++i] != '&') return null;
        operator = '&&';
      } else if (i + 1 < script.length && script[i + 1] == char) {
        return null; // no ||, ;; or shell control constructs
      }
      parts.add((
        words: List.unmodifiable(words),
        operator: operator,
        redirects: List.unmodifiable(redirects)
      ));
      redirects.clear();
      words = [];
    } else if ('\u0024`<>()[*?~#{}'.contains(char) || char.codeUnitAt(0) < 32) {
      return null;
    } else {
      word.write(char);
      active = true;
    }
  }
  if (quote != null) return null;
  if (active) words.add(word.toString());
  if (words.isEmpty || words.first.isEmpty) return null;
  parts.add((
    words: List.unmodifiable(words),
    operator: null,
    redirects: List.unmodifiable(redirects)
  ));
  return parts;
}

ProcessRequest _partRequest(ProcessRequest request, List<String> words) => (
      command: words.first,
      arguments: List.unmodifiable(words.skip(1)),
      workingDirectory: request.workingDirectory,
      environment: request.environment,
      stdin: request.stdin,
      timeout: request.timeout
    );

/// Read-only git subcommands with their certified flags. The subcommand must
/// be the first argument; a flag before it (or none given) is unrecognized.
/// Configuration overrides, output files and plumbing options are excluded.
/// Only enumerated long flags and value options are recognized. Digits are accepted in
/// short-flag clusters for the `-3` / `-n5` count shortcuts, which take no
/// separate value.
///
/// `branch` and `tag` are list-mode only: their bare positional form creates
/// a ref, so they certify only when the list flag is present or there is
/// nothing to create.
const _gitReaders = <String, _GitOptions>{
  'status': _GitOptions('sbvpohz'),
  'diff': _GitOptions('CcMnprRstTuUWyZaABbxz', numericContext: true),
  'log': _GitOptions('DEFGgfLlMmoprtZz', numericContext: true),
  'show': _GitOptions('DEFGgfLlMmoprSstZz', numericContext: true),
  'branch': _GitOptions('aAvlq'),
  'tag': _GitOptions('l'),
};

const _gitFlags = {
  '--short',
  '--branch',
  '--porcelain',
  '--porcelain=v1',
  '--porcelain=v2',
  '--oneline',
  '--stat',
  '--shortstat',
  '--numstat',
  '--name-only',
  '--name-status',
  '--no-patch',
  '--patch',
  '--raw',
  '--summary',
  '--check',
  '--no-color',
  '--color=never',
  '--decorate',
  '--no-decorate',
  '--all',
  '--graph',
  '--reverse',
  '--date-order',
  '--topo-order',
  '--first-parent',
  '--no-merges',
  '--merges',
  '--no-ext-diff',
  '--no-textconv',
  '--list',
};
const _gitValues = {
  '--format',
  '--pretty',
  '--max-count',
  '--since',
  '--until',
  '--author',
  '--grep',
  '--date',
  '--abbrev',
  '--unified',
};

final class _GitOptions {
  const _GitOptions(this.flags, {this.numericContext = false});
  final String flags;
  final bool numericContext;
}

/// Whether [request] is `git <readersubcommand> [flags] [revisions...]` with
/// only the enumerated options; `--` separates literal revisions and paths.
bool _acceptsGit(List<String> args) {
  if (args.isEmpty) return false;
  final subcommand = args.first;
  final options = _gitReaders[subcommand];
  if (options == null) return false;
  var listMode = false;
  var positional = false;
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--') {
      positional = positional || i + 1 < args.length;
      break;
    }
    if (arg == '-') return false;
    if (!arg.startsWith('-')) {
      positional = true;
      continue;
    }
    if (arg.startsWith('--')) {
      if (_gitFlags.contains(arg)) {
        if (arg == '--list') listMode = true;
        continue;
      }
      final equals = arg.indexOf('=');
      final option = equals < 0 ? arg : arg.substring(0, equals);
      if (!_gitValues.contains(option) ||
          !{'log', 'show', 'diff'}.contains(subcommand)) return false;
      if (equals < 0 && ++i >= args.length) return false;
      continue;
    }
    for (var j = 1; j < arg.length; j++) {
      final flag = arg[j];
      if (!options.flags.contains(flag) &&
          !(options.numericContext && RegExp(r'[0-9]').hasMatch(flag))) {
        return false;
      }
      if ((subcommand == 'branch' || subcommand == 'tag') && flag == 'l') {
        listMode = true;
      }
    }
  }
  // `git branch <name>` and `git tag <name>` create refs, not lists.
  if ((subcommand == 'branch' || subcommand == 'tag') &&
      positional &&
      !listMode) {
    return false;
  }
  return true;
}

List<String> certifiedReaderArguments(ProcessRequest request) {
  if (path.basename(request.command) == 'rg')
    return ['--no-config', ...request.arguments];
  if (path.basename(request.command) != 'git') return request.arguments;
  final arguments = request.arguments;
  return [
    '--no-pager',
    '-c',
    'core.fsmonitor=false',
    '-c',
    'core.hooksPath=/dev/null',
    arguments.first,
    if ({'diff', 'show', 'log'}.contains(arguments.first)) ...[
      '--no-ext-diff',
      '--no-textconv'
    ],
    ...arguments.skip(1),
  ];
}

bool _acceptsFind(List<String> arguments) {
  const values = {
    '-name',
    '-iname',
    '-path',
    '-ipath',
    '-type',
    '-maxdepth',
    '-mindepth'
  };
  const flags = {'-print', '-print0', '-empty', '-not', '!', '-a', '-o'};
  var expression = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (values.contains(argument)) {
      expression = true;
      if (++index >= arguments.length) return false;
    } else if (flags.contains(argument)) {
      expression = true;
    } else if (expression || argument.startsWith('-')) {
      return false;
    }
  }
  return true;
}

/// A print-only `sed` form: exactly `-n`, one script of address-and-print or
/// address-and-quit commands, then paths. The certified scripts are limited to
/// `p` and `q` — which take no flags — over numeric or `$` addresses, so any
/// other sed feature (substitutions, `w`, `e`, `i`) is structurally
/// unrecognized and uses the invocation's execution profile instead.
final _sedPrintCommand = RegExp(r'^(\d+(,\d+)?|\$)?[pq]$');

/// The accepted `-n` script list, or null when [arguments] is anything else.
/// `-f`/`--file`, `-i`, substitutions and `--output` all miss and ask.
List<String>? _sedPrintArguments(List<String> arguments) {
  if (arguments.length < 2 || arguments.first != '-n') return null;
  for (final command in arguments[1].split(';')) {
    if (command.isEmpty || !_sedPrintCommand.hasMatch(command)) return null;
  }
  return arguments;
}

/// A single literal reader may also reuse a saved directory read grant.
/// Redirects — even output-only ones — disqualify this path: it drops them,
/// and a script whose meaning depends on `2>&1` must not silently lose it.
ProcessRequest? literalShellRequest(ProcessRequest request) {
  final parts = _literalShellParts(request);
  return parts?.length == 1 && parts!.single.redirects.isEmpty
      ? _partRequest(request, parts.single.words)
      : null;
}

/// Certify every component and reconstruct the shell script with pinned
/// trusted executables and quoted literal arguments. No PATH lookup or shell
/// expansion remains in the script that is executed. File output requires an
/// already-writable directory; Git gets its read-only environment per component.
ProcessRequest? readOnlyShellRequest(ProcessRequest request,
    {String? searchPath,
    Map<String, String> trustedExecutables = const {},
    bool Function(String)? canWrite}) {
  final parts = _literalShellParts(request);
  if (parts == null) return null;
  final script = StringBuffer();
  String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
  for (final part in parts) {
    final component = _partRequest(request, part.words);
    final executable = readOnlyExecutable(component,
        searchPath: searchPath, trustedExecutables: trustedExecutables);
    if (executable == null) return null;
    if (path.basename(executable) == 'git') {
      script.write("'/usr/bin/env' 'GIT_OPTIONAL_LOCKS=0' ");
    }
    script.write([executable, ...certifiedReaderArguments(component)]
        .map(quote)
        .join(' '));
    for (final redirect in part.redirects) {
      if (redirect.target != null) {
        try {
          final target = canonicalSandboxPath(path.isAbsolute(redirect.target!)
              ? redirect.target!
              : path.join(request.workingDirectory ?? Directory.current.path,
                  redirect.target!));
          if (canWrite?.call(target) != true ||
              canWrite?.call(path.dirname(target)) != true) return null;
        } on FileSystemException {
          return null;
        }
      }
      script.write(' ${redirect.text}');
    }
    if (part.operator != null) script.write(' ${part.operator} ');
  }
  return (
    command: '/bin/sh',
    arguments: ['-c', script.toString()],
    workingDirectory: request.workingDirectory,
    environment: request.environment,
    stdin: request.stdin,
    timeout: request.timeout,
  );
}

/// Certifies system readers and explicitly trusted, version-pinned readers.
/// Unknown options, custom environments and replacement programs use the
/// invocation's execution profile without reader-specific hardening. An
/// enforced read-only profile still permits workspace inspection. The returned
/// absolute path is also used at spawn, so
/// a different PATH inside the OS sandbox cannot select a different program.
String? readOnlyExecutable(ProcessRequest request,
    {String? searchPath,
    Map<String, String> trustedExecutables = const {},
    bool candidateOnly = false}) {
  if (request.environment != null || Platform.isWindows) return null;
  final name = path.basename(request.command);
  final options = _readers[name];
  final gitReader = name == 'git' && _acceptsGit(request.arguments);
  final sedPrint =
      name == 'sed' && _sedPrintArguments(request.arguments) != null;
  final accepted = options != null
      ? name == 'echo' || options.accepts(request.arguments)
      : gitReader ||
          sedPrint ||
          name == 'find' && _acceptsFind(request.arguments);
  if (!accepted) return null;
  final trusted = {'/bin/$name', '/usr/bin/$name'};
  String? candidate;
  if (request.command == name) {
    for (final directory
        in (searchPath ?? Platform.environment['PATH'] ?? '').split(':')) {
      final file = File(path.join(
          path.isAbsolute(directory)
              ? directory
              : path.join(request.workingDirectory ?? Directory.current.path,
                  directory),
          name));
      try {
        final stat = file.statSync();
        if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
          candidate = file.path;
          break;
        }
      } on FileSystemException {
        return null;
      }
    }
  } else if (path.isAbsolute(request.command)) {
    candidate = request.command;
  }
  if (candidate == null) return null;
  try {
    final resolved = File(candidate).resolveSymbolicLinksSync();
    final stat = File(resolved).statSync();
    if (stat.type != FileSystemEntityType.file || stat.mode & 0x49 == 0)
      return null;
    if (!trusted.contains(resolved) && stat.size > 64 * 1024 * 1024) return null;
    // Comparing against literal system paths also rejects a system-name
    // symlink that points to a script or executable in a writable directory.
    return trusted.contains(resolved) ||
            candidateOnly ||
            trustedExecutables[resolved] ==
                sha256.convert(File(resolved).readAsBytesSync()).toString()
        ? resolved
        : null;
  } on FileSystemException {
    return null;
  }
}

List<String>? _readTargets(ProcessRequest request, {bool reportOnly = false}) {
  final name = path.basename(request.command);
  if (name == 'echo') return const [];
  if (name == 'git') {
    if (!_acceptsGit(request.arguments)) return null;
    // Reads reach the repository root through gitdir links even from a
    // subdirectory. The working directory itself is the reported target.
    return [
      _resolveTarget(request.workingDirectory ?? Directory.current.path,
          request.workingDirectory ?? Directory.current.path),
    ];
  }
  if (name == 'find') {
    if (!_acceptsFind(request.arguments)) return null;
    final operands = request.arguments
        .takeWhile((argument) => !argument.startsWith('-') && argument != '!')
        .toList();
    try {
      return (operands.isEmpty ? ['.'] : operands)
          .map((operand) => _resolveTarget(
              operand, request.workingDirectory ?? Directory.current.path))
          .toList();
    } on FileSystemException {
      return null;
    }
  }
  if (name == 'sed') {
    if (_sedPrintArguments(request.arguments) == null) return null;
    final files = request.arguments.skip(2).toList();
    if (files.isEmpty) return const [];
    try {
      return files
          .map((file) => _resolveTarget(
              file, request.workingDirectory ?? Directory.current.path))
          .toList();
    } on FileSystemException {
      return null;
    }
  }
  final options = _readers[name];
  if (options == null || !options.accepts(request.arguments)) return null;
  final positional = <String>[];
  final files = <String>[];
  var explicitPattern = false;
  var literal = false;
  var recursive = false;
  final args = request.arguments;
  void value(String flag, String text) {
    if ({'grep', 'rg'}.contains(name) &&
        {'f', '--file', '--exclude-from'}.contains(flag)) {
      if (text != '-') files.add(text);
    }
    if ({'grep', 'rg'}.contains(name) &&
        {'e', 'f', '--regexp', '--file'}.contains(flag)) {
      explicitPattern = true;
    }
  }

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (literal || arg == '-' || !arg.startsWith('-')) {
      positional.add(arg);
    } else if (arg == '--') {
      literal = true;
    } else if (arg.startsWith('--')) {
      final equals = arg.indexOf('=');
      final flag = equals < 0 ? arg : arg.substring(0, equals);
      if (name == 'grep' &&
          {'--recursive', '--dereference-recursive'}.contains(flag))
        recursive = true;
      if (options.longValues.contains(flag)) {
        value(flag, equals < 0 ? args[++i] : arg.substring(equals + 1));
      }
    } else {
      for (var j = 1; j < arg.length; j++) {
        final flag = arg[j];
        if (name == 'grep' && (flag == 'r' || flag == 'R')) recursive = true;
        if (options.values.contains(flag)) {
          value(flag, j + 1 < arg.length ? arg.substring(j + 1) : args[++i]);
          break;
        }
      }
    }
  }
  if ({'grep', 'rg'}.contains(name) &&
      !explicitPattern &&
      !(name == 'rg' && args.contains('--files'))) {
    if (positional.isEmpty) return null;
    positional.removeAt(0);
  }
  files.addAll(positional.where((value) => value != '-'));
  // Preserve the reader gate's policy; reporting stream-only readers must
  // not invent an access to cwd when they consume stdin.
  if (files.isEmpty &&
      (!reportOnly || name == 'ls' || name == 'grep' && recursive)) {
    files.add('.');
  }
  try {
    return files.map((file) => _resolveTarget(
        file, request.workingDirectory ?? Directory.current.path)).toList();
  } on FileSystemException {
    return null;
  }
}

/// Resolve one path operand to its canonical absolute path.
String _resolveTarget(String file, String workingDirectory) {
  final absolute =
      path.isAbsolute(file) ? file : path.join(workingDirectory, file);
  return File(absolute).resolveSymbolicLinksSync();
}

/// Patterns and display options are not paths; pattern files are paths.
bool readsGrantedDirectories(ProcessRequest request,
    ReadOnlyDirectories directories, String? workspaceRoot) {
  if (directories.paths.isEmpty) return false;
  final targets = _readTargets(request);
  if (targets == null) return false;
  return targets.every((target) =>
      directories.allows(target) ||
      workspaceRoot != null && _inWorkspace(target, workspaceRoot));
}

String? readDirectoryForRequest(ProcessRequest request, String? workspaceRoot) {
  final targets = _readTargets(request);
  if (targets == null) return null;
  for (final target in targets) {
    if (workspaceRoot != null && _inWorkspace(target, workspaceRoot)) continue;
    return Directory(target).existsSync() ? target : path.dirname(target);
  }
  return null;
}

/// Known path operands only. This report does not certify additional commands
/// or authorize execution; the existing reader gate retains that responsibility.
List<PermissionAccess> verifiedReaderAccesses(ProcessRequest request,
    {String? searchPath, Map<String, String> trustedExecutables = const {}}) {
  final parts = _literalShellParts(request);
  final components = parts == null
      ? [request]
      : parts.map((part) => _partRequest(request, part.words)).toList();
  final accesses = <PermissionAccess>[];
  for (final component in components) {
    if (readOnlyExecutable(component,
            searchPath: searchPath, trustedExecutables: trustedExecutables) ==
        null) continue;
    for (final target
        in _readTargets(component, reportOnly: true) ?? const <String>[]) {
      accesses.add(PermissionAccess(
          PermissionAccessOperation.read,
          target,
          Directory(target).existsSync()
              ? PermissionTargetKind.directory
              : PermissionTargetKind.file));
    }
  }
  if (parts != null) {
    for (final part in parts) {
      for (final redirect in part.redirects) {
        if (redirect.target != null) {
          final target = canonicalSandboxPath(path.isAbsolute(redirect.target!)
              ? redirect.target!
              : path.join(request.workingDirectory ?? Directory.current.path,
                  redirect.target!));
          accesses.add(PermissionAccess(PermissionAccessOperation.write, target,
              PermissionTargetKind.file));
        }
      }
    }
  }
  return accesses;
}

/// Complete only when every component is a certified reader and every path
/// operand resolved. A partial report must never enable precedent reuse.
bool hasCompleteReaderAccesses(ProcessRequest request,
    {String? searchPath, Map<String, String> trustedExecutables = const {}}) {
  final parts = _literalShellParts(request);
  final components = parts == null
      ? [request]
      : parts.map((part) => _partRequest(request, part.words));
  return components.every((component) =>
      readOnlyExecutable(component,
              searchPath: searchPath, trustedExecutables: trustedExecutables) !=
          null &&
      _readTargets(component, reportOnly: true) != null);
}

bool _inWorkspace(String target, String workspace) {
  try {
    final root = Directory(workspace).resolveSymbolicLinksSync();
    return path.equals(target, root) || path.isWithin(root, target);
  } on FileSystemException {
    return false;
  }
}

class _ReaderOptions {
  const _ReaderOptions(this.flags, this.values, this.longFlags, this.longValues,
      {this.longOptional = const {}, this.numericContext = false});
  final String flags, values;
  final Set<String> longFlags, longValues, longOptional;
  final bool numericContext;

  bool accepts(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') return true; // remaining arguments are literal operands
      if (arg == '-' || !arg.startsWith('-')) continue;
      if (arg.startsWith('--')) {
        final equals = arg.indexOf('=');
        final name = equals < 0 ? arg : arg.substring(0, equals);
        if (longFlags.contains(name) && equals < 0) continue;
        if (longOptional.contains(name)) continue;
        if (!longValues.contains(name)) return false;
        if (equals < 0 && ++i >= args.length) return false;
      } else {
        for (var j = 1; j < arg.length; j++) {
          final flag = arg[j];
          if (flags.contains(flag) ||
              (numericContext && RegExp(r'[0-9]').hasMatch(flag))) continue;
          if (!values.contains(flag)) return false;
          if (j == arg.length - 1 && ++i >= args.length) return false;
          break; // attached or next argument is the option's literal value
        }
      }
    }
    return true;
  }
}

// GNU and BSD reader options. Deliberately no interpreters, wrappers, find,
// sed, git, ripgrep preprocessors or output-file options. A miss asks.
const _readers = {
  'rg': _ReaderOptions('nNihHsSluUcwvqxFoILaz', 'efgtTmABC', {
    '--files',
    '--hidden',
    '--no-ignore',
    '--no-ignore-vcs',
    '--no-config',
    '--line-number',
    '--no-line-number',
    '--ignore-case',
    '--smart-case',
    '--case-sensitive',
    '--fixed-strings',
    '--word-regexp',
    '--line-regexp',
    '--files-with-matches',
    '--files-without-match',
    '--count',
    '--count-matches',
    '--only-matching',
    '--quiet',
    '--text',
    '--null',
    '--null-data',
    '--heading',
    '--no-heading',
    '--with-filename',
    '--no-filename',
    '--multiline',
    '--multiline-dotall',
    '--pcre2',
    '--invert-match',
    '--help',
    '--version',
  }, {
    '--regexp',
    '--file',
    '--glob',
    '--iglob',
    '--type',
    '--type-not',
    '--max-count',
    '--max-depth',
    '--before-context',
    '--after-context',
    '--context',
    '--color',
    '--colors',
    '--sort',
    '--sortr',
    '--encoding'
  }),
  'wc': _ReaderOptions('clLmw', '', {
    '--bytes',
    '--chars',
    '--lines',
    '--max-line-length',
    '--words',
    '--help',
    '--version'
  }, {}),
  'stat': _ReaderOptions('Llxt', '',
      {'--dereference', '--file-system', '--help', '--version'}, {}),
  'sha256sum': _ReaderOptions(
      'btz', '', {'--binary', '--text', '--zero', '--help', '--version'}, {}),
  'shasum': _ReaderOptions('bt', 'a',
      {'--binary', '--text', '--help', '--version'}, {'--algorithm'}),
  // Literal output only; echo's arguments never name files or execute code.
  'echo': _ReaderOptions('', '', {}, {}),
  'cat': _ReaderOptions('AbBenstTuv', '', {
    '--show-all',
    '--number-nonblank',
    '--show-ends',
    '--number',
    '--squeeze-blank',
    '--show-tabs',
    '--show-nonprinting',
    '--help',
    '--version'
  }, {}),
  'head': _ReaderOptions(
      'qv',
      'cn',
      {'--quiet', '--silent', '--verbose', '--help', '--version'},
      {'--bytes', '--lines'},
      numericContext: true),
  'tail': _ReaderOptions('Ffqrv', 'bcn', {
    '--follow',
    '--retry',
    '--quiet',
    '--silent',
    '--verbose',
    '--help',
    '--version'
  }, {
    '--bytes',
    '--lines'
  }),
  'ls': _ReaderOptions('aAbBcCdDfFgGhHiIkLlmnNopPqQrRsStTuUvVxX1@eO%', 'ITw', {
    '--all',
    '--almost-all',
    '--author',
    '--escape',
    '--directory',
    '--dired',
    '--file-type',
    '--full-time',
    '--human-readable',
    '--inode',
    '--kibibytes',
    '--literal',
    '--numeric-uid-gid',
    '--quote-name',
    '--recursive',
    '--reverse',
    '--size',
    '--help',
    '--version',
    '--zero',
    '--dereference',
    '--dereference-command-line',
    '--dereference-command-line-symlink-to-dir',
    '--hide-control-chars',
    '--show-control-chars',
  }, {
    '--block-size',
    '--format',
    '--hide',
    '--ignore',
    '--indicator-style',
    '--quoting-style',
    '--sort',
    '--tabsize',
    '--time',
    '--time-style',
    '--width',
  }, longOptional: {
    '--color',
    '--hyperlink',
    '--classify'
  }),
  'grep': _ReaderOptions(
      'abcEFGHhIiLlnoPqRrsSUuvVwxZz',
      'ABCDefm',
      {
        '--basic-regexp',
        '--extended-regexp',
        '--fixed-strings',
        '--perl-regexp',
        '--ignore-case',
        '--no-ignore-case',
        '--invert-match',
        '--word-regexp',
        '--line-regexp',
        '--no-messages',
        '--text',
        '--binary',
        '--byte-offset',
        '--line-number',
        '--with-filename',
        '--no-filename',
        '--files-with-matches',
        '--files-without-match',
        '--only-matching',
        '--count',
        '--quiet',
        '--silent',
        '--recursive',
        '--dereference-recursive',
        '--line-buffered',
        '--null',
        '--null-data',
        '--initial-tab',
        '--no-group-separator',
        '--help',
        '--version',
      },
      {
        '--regexp',
        '--file',
        '--max-count',
        '--after-context',
        '--before-context',
        '--context',
        '--binary-files',
        '--devices',
        '--directories',
        '--exclude',
        '--exclude-from',
        '--exclude-dir',
        '--include',
        '--include-dir',
        '--label',
        '--group-separator',
      },
      longOptional: {'--color', '--colour'},
      numericContext: true),
};
