import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'command_approval_store.dart' show resolveHostExecutable;
import 'process_runner.dart';
import 'read_only_commands.dart';
import 'sandbox_home.dart';

/// One literal command stage. Prefixes compare argv tokens, never shell text.
final class CommandPrefixStage {
  CommandPrefixStage(
      this.executable, this.arguments, this.prefix, this.context);
  final String executable, context;
  final List<String> arguments, prefix;
  String get label => prefix.map(_quote).join(' ');
  Map<String, Object?> toJson() => {
        'executable': executable,
        'arguments': arguments,
        'prefix': prefix,
        'context': context,
      };

  bool matches(Map<String, Object?> rule) {
    final words = rule['prefix'];
    return rule['executable'] == executable &&
        rule['context'] == context &&
        words is List &&
        words.isNotEmpty &&
        words.first == prefix.first &&
        words.every((word) => word is String) &&
        words.length <= arguments.length + 1 &&
        [for (var i = 1; i < words.length; i++) words[i] == arguments[i - 1]]
            .every((match) => match);
  }
}

/// Plain exec calls and literal shell lists/pipelines are eligible. Every
/// command needs its own rule, including output-only shell builtins.
/// Assignments, expansion, file redirects and state-changing builtins remain
/// invocation reviews. A head rule cannot cover an earlier or later command.
final class CommandPrefixPlan {
  CommandPrefixPlan._(this.stages);
  final List<CommandPrefixStage> stages;
  String get identity => jsonEncode(stages.map((s) => s.toJson()).toList());
  List<String> get labels => stages.map((s) => s.label).toSet().toList();

  static CommandPrefixPlan? parse(ProcessRequest request,
      {required String workspace,
      String? searchPath,
      String? sandboxHomeRoot,
      void Function(String reason)? onUnavailable}) {
    CommandPrefixPlan? unavailable(String reason) {
      onUnavailable?.call(reason);
      return null;
    }

    try {
      final shell = const {'sh', 'bash', 'dash', 'zsh', 'ksh'}
          .contains(p.basename(request.command));
      String? launcher;
      List<ShellCommandPart>? parts;
      if (shell) {
        launcher = resolveHostExecutable(request,
            workspace: workspace, searchPath: searchPath);
        // This grammar is POSIX sh. Do not guess at other interpreters' syntax.
        if (![
          '/bin/sh',
          '/bin/bash',
          '/usr/bin/sh',
          '/usr/bin/bash',
          '/bin/dash',
          '/usr/bin/dash'
        ].contains(launcher)) {
          return unavailable('This shell is not supported for saved prefixes.');
        }
        parts = literalShellParts((
          command: '/bin/sh',
          arguments: request.arguments,
          workingDirectory: request.workingDirectory,
          environment: request.environment,
          stdin: request.stdin,
          timeout: request.timeout,
        ));
        if (parts == null) {
          return unavailable('Only literal commands joined by ;, && or | can '
              'be remembered. Split commands that use expansion, control '
              'flow or other shell syntax.');
        }
        if (parts.any((part) =>
            part.redirects.any((redirect) => redirect.target != null))) {
          return unavailable('File redirections require review for each '
              'invocation. Split the redirected command to remember the others.');
        }
      } else {
        parts = [
          (
            words: [request.command, ...request.arguments],
            operator: null,
            redirects: const <({String text, String? target})>[]
          )
        ];
      }
      final environment = request.environment;
      final identityEnvironment = environment == null
          ? null
          : {
              for (final entry in environment.entries)
                entry.key: sandboxHomeRoot != null &&
                        {'HOME', 'TMPDIR'}.contains(entry.key) &&
                        sandboxPathUnder(entry.value, sandboxHomeRoot)
                    ? '$sandboxHomeRoot/<private-${entry.key}>'
                    : entry.value,
            };
      final keys = environment?.keys.toList()?..sort();
      final stages = <CommandPrefixStage>[];
      for (final part in parts) {
        final words = part.words;
        final name = p.basename(words.first);
        final arguments = words.skip(1).toList();
        final builtin =
            shell && words.first == name && _builtins.contains(name);
        if (_wrappers.contains(name) ||
            builtin && !_literalBuiltins.contains(name) ||
            words.first.contains('=') ||
            words.first.startsWith('-')) {
          return unavailable('Shell setup, state-changing builtins and '
              'interpreter wrappers cannot be remembered as prefixes. '
              'Split them from the commands you want to remember.');
        }
        // A builtin is executed by the selected shell, not the external
        // executable of the same name found on PATH. Keep their rules distinct.
        final executable = builtin
            ? launcher!
            : resolveHostExecutable((
                command: words.first,
                arguments: words.skip(1).toList(),
                workingDirectory: request.workingDirectory,
                environment: environment,
                stdin: request.stdin,
                timeout: request.timeout,
              ), workspace: workspace, searchPath: searchPath);
        final depth = _subcommands[name];
        final prefix = <String>[name];
        if (depth != null) {
          for (final argument in arguments.take(depth)) {
            if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(argument)) break;
            prefix.add(argument);
          }
          if (prefix.length == 1) {
            return unavailable('$name needs a literal subcommand before a '
                'prefix can be remembered.');
          }
        }
        final context = sha256
            .convert(utf8.encode(jsonEncode([
              canonicalSandboxPath(request.workingDirectory ?? workspace),
              launcher,
              if (keys == null)
                null
              else
                {for (final key in keys) key: identityEnvironment![key]},
              request.stdin,
              part.redirects.map((r) => r.text).toList(),
              if (builtin) 'shell-builtin:$name',
            ])))
            .toString();
        stages.add(CommandPrefixStage(executable, List.unmodifiable(arguments),
            List.unmodifiable(prefix), context));
      }
      return CommandPrefixPlan._(List.unmodifiable(stages));
    } on FileSystemException {
      return unavailable('An executable could not be resolved. Check its path '
          'before remembering a prefix.');
    }
  }
}

// These do not change shell state. printf is deliberately excluded: both -v
// and the bash %n format can assign shell variables, including PATH.
const _literalBuiltins = {'echo', 'pwd', 'true', 'false'};

const _subcommands = {
  'gh': 2,
  'git': 1,
  'docker': 1,
  'kubectl': 1,
  'dart': 1,
  'flutter': 1,
  'cargo': 1,
  'go': 1,
  'npm': 1,
  'pnpm': 1
};
const _wrappers = {
  'sh',
  'bash',
  'zsh',
  'dash',
  'ksh',
  'fish',
  'env',
  'sudo',
  'doas',
  'xargs',
  'busybox',
  'python',
  'python3',
  'node',
  'ruby',
  'perl'
};
const _builtins = {
  ':',
  'enable',
  'readonly',
  'typeset',
  'let',
  'getopts',
  'shopt',
  'pushd',
  'popd',
  'dirs',
  'mapfile',
  'readarray',
  'bind',
  'complete',
  'compgen',
  'compopt',
  'history',
  'fc',
  'jobs',
  'fg',
  'bg',
  'wait',
  'kill',
  'disown',
  'logout',
  'suspend',
  'help',
  'caller',
  'times',
  'ulimit',
  'break',
  'continue',
  'select',
  'in',
  'coproc',
  '[[',
  ']]',
  'cd',
  'export',
  'unset',
  'alias',
  'unalias',
  'eval',
  'exec',
  'command',
  'builtin',
  'source',
  '.',
  'read',
  'printf',
  'echo',
  'pwd',
  'test',
  '[',
  'true',
  'false',
  'exit',
  'return',
  'set',
  'shift',
  'trap',
  'umask',
  'type',
  'hash',
  'time',
  '!',
  'if',
  'then',
  'else',
  'fi',
  'for',
  'while',
  'until',
  'do',
  'done',
  'case',
  'esac',
  'function',
  'local',
  'declare'
};

String _quote(String value) => RegExp(r'^[A-Za-z0-9_./:+-]+$').hasMatch(value)
    ? value
    : "'${value.replaceAll("'", "'\\''")}'";
