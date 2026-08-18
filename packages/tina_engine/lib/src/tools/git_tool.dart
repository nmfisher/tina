import 'process_runner.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Subcommands that are read-only with any arguments — no flag combination
/// under these can mutate the repo, so they need no further guarding.
const Set<String> _readOnlySubcommands = {
  'status',
  'log',
  'diff',
  'show',
  'blame',
  'ls-files',
  'describe',
  'shortlog',
  'rev-parse',
  'reflog',
};

/// Subcommands that mutate under some forms, allowed here only in their
/// listing shapes. Each has a dedicated guard below.
const Set<String> _restrictedSubcommands = {'branch', 'tag', 'remote'};

/// Human-readable form of what's allowed — embedded in rejection errors so
/// the model self-corrects on the next call instead of guessing.
const String _allowlistHelp =
    'read-only git subcommands (status, log, diff, show, blame, ls-files, '
    'describe, shortlog, rev-parse, reflog) and the listing forms of branch, '
    'tag, and remote';

/// Runs read-only git queries without the bash approval prompt. The
/// subcommand allowlist (plus per-subcommand guards for `branch`/`tag`/
/// `remote`) is what makes this tool safe to auto-allow: no argument
/// combination that reaches the shell can mutate anything. Mutating git
/// work still goes through `bash` and its permission prompt.
class GitTool implements Tool {
  final ProcessRunner processRunner;

  /// Working directory for the git invocation. Defaults to the process cwd
  /// (re-pointed at the project root at composition, like BashTool's
  /// `projectRoot`); tests point it at a temp repo.
  String? workingDirectory;

  GitTool({ProcessRunner? processRunner, this.workingDirectory})
      : processRunner = processRunner ?? const IoProcessRunner();

  @override
  ToolSchema get schema => ToolSchema(
        name: 'git',
        description:
            'Run a read-only git query: $_allowlistHelp. Pass the subcommand '
            'and its arguments, e.g. "log --oneline -5", "status", '
            '"diff HEAD~1". Mutating git operations are not available here — '
            'use bash for those (it will ask for approval).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'args': {
              'type': 'string',
              'description': 'Git arguments after "git", e.g. '
                  '"log --oneline -5" or "show HEAD:pubspec.yaml".',
            },
          },
          'required': ['args'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String args;
    try {
      args = requiredString(input, 'args');
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    final parts = args
        .trim()
        .split(RegExp(r'\s+'))
        .where((a) => a.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return ToolResult.error('args is required');
    }
    final violation = _readOnlyViolation(parts);
    if (violation != null) {
      return ToolResult.error(violation);
    }

    final result = await processRunner.run(
      'git',
      parts,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) {
      final err = result.stderr.trim();
      return ToolResult.error(
          err.isEmpty ? 'git exited ${result.exitCode}' : err);
    }
    final out = result.stdout.trimRight();
    return ToolResult(out.isEmpty ? '(no output)' : out);
  }

  /// Null when [parts] is a read-only invocation; otherwise a human-readable
  /// rejection. The dispatch is: allowlisted subcommands pass through,
  /// restricted ones are checked in their listing forms, everything else is
  /// rejected.
  String? _readOnlyViolation(List<String> parts) {
    // Even a read-only subcommand can write a file via `--output`/`--output=`
    // (e.g. `git log --output=/tmp/x`); since this tool is auto-allowed,
    // reject it outright.
    for (final arg in parts) {
      if (arg == '--output' || arg.startsWith('--output=')) {
        return 'git --output writes a file — not allowed here.';
      }
    }
    final sub = parts.first;
    final rest = parts.sublist(1);
    if (_readOnlySubcommands.contains(sub)) return null;
    if (!_restrictedSubcommands.contains(sub)) {
      return 'git $sub is not allowed here — this tool runs only '
          '$_allowlistHelp. Mutating operations need bash.';
    }
    return switch (sub) {
      'branch' => _guard(rest, subcommand: 'branch', flags: {
          '-d', '-D', '-m', '-M', '-t', '--edit-description', '--set-upstream-to',
        }, operandsRequireList: true),
      'tag' => _guard(rest, subcommand: 'tag', flags: {
          '-d', '-f', '-s', '-a', '-m', '-u',
        }, operandsRequireList: true),
      'remote' => _guardRemote(rest),
      _ => 'git $sub is not allowed here',
    };
  }

  /// Shared guard for `branch`/`tag`: only listing forms. Any mutating flag
  /// rejects; a non-flag operand (a branch/tag name to create) rejects
  /// unless `--list` is present.
  String? _guard(
    List<String> rest, {
    required String subcommand,
    required Set<String> flags,
    required bool operandsRequireList,
  }) {
    var hasList = false;
    var sawOperand = false;
    for (final arg in rest) {
      if (arg == '-l' || arg == '--list') {
        hasList = true;
      } else if (arg.startsWith('-')) {
        if (flags.contains(arg)) {
          return 'git $subcommand $arg mutates the repo — not allowed here. '
              'Only listing forms of $subcommand are available ($_allowlistHelp).';
        }
      } else {
        sawOperand = true;
      }
    }
    if (sawOperand && operandsRequireList && !hasList) {
      return 'git $subcommand <name> creates/points at a ref — not allowed '
          'here. Use a listing form (bare, -l/--list, -a, -v).';
    }
    return null;
  }

  /// `remote` guard: bare / -v / get-url <name> only. `remote add` etc. are
  /// sub-subcommands, i.e. the first operand decides.
  String? _guardRemote(List<String> rest) {
    const mutating = {'add', 'remove', 'rm', 'rename', 'set-url', 'set-head',
        'prune', 'update'};
    if (rest.isEmpty) return null;
    final first = rest.first;
    if (mutating.contains(first)) {
      return 'git remote $first mutates the repo config — not allowed here. '
          'Only bare `git remote`, `-v`, and `get-url` are available.';
    }
    if (first.startsWith('-')) {
      // `git remote -v` and friends are query flags; anything else still
      // can't mutate (the mutating forms are operand-led, already rejected).
      return null;
    }
    if (first == 'get-url') return null;
    return 'git remote $first is not supported here — use bare `git remote`, '
        '`-v`, or `get-url <name>`.';
  }
}
