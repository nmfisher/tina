import 'dart:io';

import 'package:path/path.dart' as path;

import 'process_runner.dart';

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
