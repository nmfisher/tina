import 'dart:io';

import 'package:path/path.dart' as path;

import 'process_runner.dart';
import 'read_directories.dart';

/// Parse a single literal POSIX command for separate reader certification.
/// Expansions, redirections, pipelines and scripts retain normal approval.
ProcessRequest? literalShellRequest(ProcessRequest request) {
  if (request.command != '/bin/sh' ||
      request.arguments.length != 2 ||
      request.arguments.first != '-c') return null;
  final script = request.arguments.last;
  if (script.contains('\n') || script.contains('\r')) return null;
  final words = <String>[];
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
      if (quote == '"' && !'"\u0024`\\'.contains(escaped)) return null;
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
    } else if ('\u0024`|&;<>()[*?~#{}'.contains(char) || char == '\u0000') {
      return null;
    } else {
      word.write(char);
      active = true;
    }
  }
  if (quote != null) return null;
  if (active) words.add(word.toString());
  if (words.isEmpty || words.first.isEmpty) return null;
  return (
    command: words.first,
    arguments: List.unmodifiable(words.skip(1)),
    workingDirectory: request.workingDirectory,
    environment: request.environment,
    stdin: request.stdin,
    timeout: request.timeout
  );
}

/// Certifies a narrow set of system readers, never a shell command string.
/// Unknown options, custom environments and replacement programs fall back
/// to normal approval. The returned absolute path is also used at spawn, so
/// a different PATH inside the OS sandbox cannot select a different program.
String? readOnlyExecutable(ProcessRequest request, {String? searchPath}) {
  if (request.environment != null || Platform.isWindows) return null;
  final name = path.basename(request.command);
  final options = _readers[name];
  if (options == null || !options.accepts(request.arguments)) return null;
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
  } else if (trusted.contains(request.command)) {
    candidate = request.command;
  }
  if (candidate == null) return null;
  try {
    final resolved = File(candidate).resolveSymbolicLinksSync();
    // Comparing against literal system paths also rejects a system-name
    // symlink that points to a script or executable in a writable directory.
    return trusted.contains(resolved) ? resolved : null;
  } on FileSystemException {
    return null;
  }
}

List<String>? _readTargets(ProcessRequest request) {
  final name = path.basename(request.command);
  final options = _readers[name];
  if (options == null || !options.accepts(request.arguments)) return null;
  final positional = <String>[];
  final files = <String>[];
  var explicitPattern = false;
  var literal = false;
  final args = request.arguments;
  void value(String flag, String text) {
    if (name == 'grep' && {'f', '--file', '--exclude-from'}.contains(flag)) {
      if (text != '-') files.add(text);
    }
    if (name == 'grep' && {'e', 'f', '--regexp', '--file'}.contains(flag)) {
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
      if (options.longValues.contains(flag)) {
        value(flag, equals < 0 ? args[++i] : arg.substring(equals + 1));
      }
    } else {
      for (var j = 1; j < arg.length; j++) {
        final flag = arg[j];
        if (options.values.contains(flag)) {
          value(flag, j + 1 < arg.length ? arg.substring(j + 1) : args[++i]);
          break;
        }
      }
    }
  }
  if (name == 'grep' && !explicitPattern) {
    if (positional.isEmpty) return null;
    positional.removeAt(0);
  }
  files.addAll(positional.where((value) => value != '-'));
  if (files.isEmpty) files.add('.');
  try {
    return files.map((file) {
      final absolute = path.isAbsolute(file)
          ? file
          : path.join(request.workingDirectory ?? Directory.current.path, file);
      return File(absolute).resolveSymbolicLinksSync();
    }).toList();
  } on FileSystemException {
    return null;
  }
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
      {'--bytes', '--lines'}),
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
