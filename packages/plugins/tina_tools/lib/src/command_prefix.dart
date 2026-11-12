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

/// Only plain exec calls and literal pipelines are eligible. Assignments,
/// expansion, command lists, file redirects and shell builtins stay reviewed
/// as whole invocations. A saved head rule cannot cover another pipeline stage.
final class CommandPrefixPlan {
  CommandPrefixPlan._(this.stages);
  final List<CommandPrefixStage> stages;
  String get identity => jsonEncode(stages.map((s) => s.toJson()).toList());
  List<String> get labels => stages.map((s) => s.label).toSet().toList();

  static CommandPrefixPlan? parse(ProcessRequest request,
      {required String workspace,
      String? searchPath,
      String? sandboxHomeRoot}) {
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
        ].contains(launcher)) return null;
        parts = literalShellParts((
          command: '/bin/sh',
          arguments: request.arguments,
          workingDirectory: request.workingDirectory,
          environment: request.environment,
          stdin: request.stdin,
          timeout: request.timeout,
        ));
        if (parts == null ||
            parts.any((part) =>
                part.operator != null && part.operator != '|' ||
                part.redirects.any((redirect) => redirect.target != null)))
          return null;
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
        if (_wrappers.contains(name) ||
            shell && _builtins.contains(name) ||
            words.first.contains('=') ||
            words.first.startsWith('-')) return null;
        final executable = resolveHostExecutable((
          command: words.first,
          arguments: words.skip(1).toList(),
          workingDirectory: request.workingDirectory,
          environment: environment,
          stdin: request.stdin,
          timeout: request.timeout,
        ), workspace: workspace, searchPath: searchPath);
        final arguments = words.skip(1).toList();
        final depth = _subcommands[name];
        final prefix = <String>[name];
        if (depth != null) {
          for (final argument in arguments.take(depth)) {
            if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(argument)) break;
            prefix.add(argument);
          }
          if (prefix.length == 1) return null;
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
            ])))
            .toString();
        stages.add(CommandPrefixStage(executable, List.unmodifiable(arguments),
            List.unmodifiable(prefix), context));
      }
      return CommandPrefixPlan._(List.unmodifiable(stages));
    } on FileSystemException {
      return null;
    }
  }
}

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
