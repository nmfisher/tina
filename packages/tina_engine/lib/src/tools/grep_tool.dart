import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'file_enumerator.dart';
import 'file_system.dart';
import 'process_runner.dart';
import 'sandbox.dart';
import 'tool.dart';
import 'tool_input.dart';

final _log = Logger('tina.tools.grep');

/// Search file contents for a regex pattern. Tries ripgrep first; falls back
/// to a pure-Dart walk if `rg` isn't on PATH.
///
/// Subprocess execution ([processRunner]), file enumeration
/// ([fileEnumerator]), and file reads ([fs]) are all injected seams, so the
/// tool is unit-testable without spawning `rg` or touching disk.
///
/// The runtime `path` param is validated against the sandbox in [execute]:
/// the fs-fallback reads go through [fs] (a [SandboxedFileSystem] when one is
/// injected), but the `rg` subprocess path can't be covered by the seam — so
/// [sandbox] asserts the path directly (the review's H1 fix for the grep/glob
/// bypass). When [sandbox] is null (tests), the assert is skipped.
class GrepTool implements Tool {
  static const int _defaultMaxResults = 100;

  /// Per-match line cap. A single match on a minified/bundled multi-KB line
  /// would otherwise dump the whole line into context (only `_defaultMaxResults`
  /// bounds *count*, not length). Truncating from the end keeps the
  /// `path:line:` prefix intact and trims the matched content. Mirrors pi's
  /// `GREP_MAX_LINE_LENGTH`.
  static const int _maxMatchLineChars = 1000;

  final ProcessRunner processRunner;
  final FileEnumerator fileEnumerator;

  /// The filesystem this tool's Dart-fallback reads go through. Mutable so app
  /// composition can inject a [SandboxedFileSystem] once. Defaults to the real
  /// filesystem.
  late FileSystem fs;

  /// Validates the runtime `path` param against the project root + tina tree.
  /// Null in tests that don't set a sandbox.
  SandboxedFileSystem? sandbox;

  GrepTool({
    ProcessRunner? processRunner,
    FileEnumerator? fileEnumerator,
    FileSystem? fs,
    this.sandbox,
  })  : processRunner = processRunner ?? const IoProcessRunner(),
        fileEnumerator = fileEnumerator ?? RepoFileEnumerator(),
        fs = fs ?? const IoFileSystem();

  /// Cached "is `rg` available?" result. `null` until first probed; subsequent
  /// calls hit the cache.
  bool? _hasRg;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'grep',
        description:
            'Search file contents for a regex pattern. Returns matches as '
            '"path:line:content". Uses ripgrep when available, otherwise a '
            'pure-Dart fallback. Honors .gitignore via `git ls-files` in the '
            'fallback.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description': 'Regex pattern (Dart RegExp syntax).',
            },
            'path': {
              'type': 'string',
              'description':
                  'Root directory to search from. Defaults to agent cwd.',
            },
            'glob': {
              'type': 'string',
              'description':
                  'Optional file glob to limit which files are searched '
                  '(e.g. "*.dart", "lib/**/*.ts").',
            },
            'maxResults': {
              'type': 'integer',
              'description': 'Cap on returned matches (default 100).',
            },
            'caseInsensitive': {
              'type': 'boolean',
              'description': 'Case-insensitive matching (default false).',
            },
          },
          'required': ['pattern'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String pattern;
    final String path;
    final String? glob;
    final int maxResults;
    final bool caseInsensitive;
    try {
      pattern = requiredString(input, 'pattern');
      path = optionalString(input, 'path') ?? Directory.current.path;
      glob = optionalString(input, 'glob');
      maxResults = optionalInt(input, 'maxResults') ?? _defaultMaxResults;
      caseInsensitive = optionalBool(input, 'caseInsensitive') ?? false;
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }

    // The `rg` subprocess path can't be covered by the FS seam, so assert the
    // runtime path against the sandbox here (review H1). Skipped when sandbox
    // is null. Maps SandboxViolation to a clean error.
    if (sandbox != null) {
      try {
        await sandbox!.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }

    final isDir = await fs.directoryExists(path);
    final isFile = await fs.fileExists(path);
    if (!isDir && !isFile) {
      return ToolResult.error('path does not exist: $path');
    }

    if (await _ripgrepAvailable()) {
      return _ripgrep(
        pattern: pattern,
        path: path,
        glob: glob,
        maxResults: maxResults,
        caseInsensitive: caseInsensitive,
        cancelSignal: cancelSignal,
      );
    }
    return _dartGrep(
      pattern: pattern,
      path: path,
      glob: glob,
      maxResults: maxResults,
      caseInsensitive: caseInsensitive,
      cancelSignal: cancelSignal,
    );
  }

  Future<bool> _ripgrepAvailable() async {
    if (_hasRg != null) return _hasRg!;
    try {
      final res = await processRunner.run('rg', const ['--version']);
      _hasRg = res.exitCode == 0;
    } catch (e) {
      _hasRg = false;
      _log.fine('rg unavailable, using Dart fallback', e);
    }
    return _hasRg!;
  }

  Future<ToolResult> _ripgrep({
    required String pattern,
    required String path,
    required String? glob,
    required int maxResults,
    required bool caseInsensitive,
    required Future<void>? cancelSignal,
  }) async {
    final args = <String>[
      '--no-heading',
      '--line-number',
      '--with-filename',
      if (caseInsensitive) '--ignore-case',
      if (glob != null) ...['--glob', glob],
      pattern,
      path,
    ];
    final RunningProcess proc;
    try {
      proc = await processRunner.start('rg', args);
    } catch (e) {
      return ToolResult.error('Failed to start rg: $e');
    }

    cancelSignal?.then((_) {
      try {
        proc.kill();
      } catch (e) {
        _log.fine('cancel kill failed', e);
      }
    });

    final buf = StringBuffer();
    var matchCount = 0;
    var truncated = false;
    final done = Completer<void>();

    final sub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (matchCount >= maxResults) {
          if (!truncated) {
            truncated = true;
            try {
              proc.kill();
            } catch (e) {
              _log.fine('truncation kill failed', e);
            }
          }
          return;
        }
        buf.writeln(_truncate(line));
        matchCount++;
        if (matchCount >= maxResults) {
          truncated = true;
          try {
            proc.kill();
          } catch (e) {
            _log.fine('truncation kill failed', e);
          }
        }
      },
      onDone: () => done.complete(),
      onError: (Object e, StackTrace st) {
        _log.fine('rg stdout stream error', e, st);
        done.complete();
      },
    );

    final exitCode = await proc.exitCode;
    await done.future.timeout(const Duration(milliseconds: 500),
        onTimeout: () {});
    await sub.cancel();

    // rg: 0 = matches, 1 = no matches, 2+ = error.
    if (exitCode > 1 && !truncated) {
      // Drain stderr for the message.
      final err = await utf8.decoder
          .bind(proc.stderr)
          .join()
          .timeout(const Duration(milliseconds: 250), onTimeout: () => '');
      return ToolResult.error(
          'ripgrep failed (exit $exitCode): ${err.trim()}');
    }
    if (matchCount == 0) return const ToolResult('(no matches)');
    if (truncated) {
      buf.writeln('... (cap of $maxResults reached; raise maxResults)');
    }
    return ToolResult(buf.toString());
  }

  Future<ToolResult> _dartGrep({
    required String pattern,
    required String path,
    required String? glob,
    required int maxResults,
    required bool caseInsensitive,
    required Future<void>? cancelSignal,
  }) async {
    final RegExp regex;
    try {
      regex = RegExp(pattern, caseSensitive: !caseInsensitive);
    } on FormatException catch (e) {
      return ToolResult.error('invalid regex: ${e.message}');
    }

    final allFiles = await fileEnumerator.enumerate(path);
    final files = glob == null
        ? allFiles
        : allFiles.where((f) => fileGlobMatch(glob, f)).toList();

    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);

    final buf = StringBuffer();
    var matchCount = 0;
    var truncated = false;

    for (final relPath in files) {
      if (cancelled) break;
      if (matchCount >= maxResults) {
        truncated = true;
        break;
      }
      final fullPath =
          p.isAbsolute(relPath) ? relPath : p.join(path, relPath);
      if (!await fs.fileExists(fullPath)) continue;
      String text;
      try {
        text = await fs.readFileString(fullPath);
      } catch (e) {
        _log.warning('failed to read $fullPath, skipping', e);
        continue;
      }
      final lines = const LineSplitter().convert(text);
      for (var i = 0; i < lines.length; i++) {
        if (cancelled) break;
        if (matchCount >= maxResults) {
          truncated = true;
          break;
        }
        if (regex.hasMatch(lines[i])) {
          buf.writeln(_truncate('$relPath:${i + 1}:${lines[i]}'));
          matchCount++;
        }
      }
    }

    if (matchCount == 0) return const ToolResult('(no matches)');
    if (truncated) {
      buf.writeln('... (cap of $maxResults reached; raise maxResults)');
    }
    return ToolResult(buf.toString());
  }

  /// Cap [line] (a full `path:line:content` match) to [_maxMatchLineChars].
  /// Truncating from the end keeps the prefix at the front and trims only the
  /// matched content, so a minified/bundled multi-KB line can't swamp context.
  static String _truncate(String line) {
    if (line.length <= _maxMatchLineChars) return line;
    return '${line.substring(0, _maxMatchLineChars)}… [line truncated]';
  }
}
