/// The sorter: one pure function, `command → box` (plus a suggested
/// sandbox profile). Stage A of the box model.
///
/// The sorter inspects the command line statically — reusing the literal
/// shell parsing the certified-reader path already owns
/// (read_only_commands.dart: words, operators, redirects) — and asks only
/// two questions: which command family is this, and does everything it
/// names sit where a profile can contain it? It never predicts what a
/// program will do; containment does that work. Unknown constructs fall to
/// [Box.ask]: the sorter never guesses in favor of silence.
///
/// Inputs are injected ([BoxSortContext]): the workspace root, what the
/// sandbox plan can read and write, what the invocation declared, and the
/// allowlist. No filesystem probes inside — the caller supplies the
/// certified-reader facts (parsed once into the capability envelope), so
/// the same request and context always give the same box.
library;

import 'dart:io' show FileSystemException;

import 'package:path/path.dart' as path;

import 'box_allowlist.dart';
import 'box_model.dart';
import 'capability_envelope.dart';
import 'command_approval_store.dart' show approvalCommandText;
import 'process_runner.dart';
import 'read_only_commands.dart';
import 'sandbox_home.dart' show canonicalSandboxPath, sandboxPathUnder;

/// Everything the sorter needs, injected so it stays pure.
typedef BoxSortContext = ({
  /// The session's project root.
  String workspaceRoot,

  /// Whether an OS sandbox backend can enforce a profile on this host.
  bool confined,

  /// The invocation declared network access (control.networkRequested).
  bool networkRequested,

  /// The invocation explicitly requested a read-only profile.
  bool? readOnlyRequested,

  /// The invocation asked to run outside the sandbox.
  bool outsideSandboxRequested,

  /// Read directories declared for this invocation (control).
  List<String> declaredReads,

  /// Write directories declared for this invocation (control).
  List<String> declaredWrites,

  /// The whole pipeline is a certified reader (envelope.certifiedReadOnly).
  bool certifiedReadOnly,

  /// Verified read effects of a certified parse (envelope), checked
  /// against the visible world.
  List<String> verifiedReads,

  /// Whether [path] sits inside the readable world (plan-backed).
  bool Function(String path) canRead,

  /// Whether [path] sits inside the writable world (plan-backed).
  bool Function(String path) canWrite,

  /// The user's stored patterns; consulted before the family tables.
  BoxAllowlist? allowlist,
});

/// The sorted verdict: a box, the profile box 2 would run in (box 1 implies
/// [boxProfileDefault]), and the reason a report or an ask can show.
final class BoxDecision {
  const BoxDecision._(this.box, this.profile, this.reason);

  final Box box;
  final BoxProfileSpec? profile;
  final String reason;

  static BoxDecision readOnlyOf(String reason) =>
      BoxDecision._(Box.readOnly, boxProfileDefault, reason);

  static BoxDecision containedOf(BoxProfileSpec profile, String reason) =>
      BoxDecision._(Box.contained, profile, reason);

  static BoxDecision askOf(String reason) =>
      BoxDecision._(Box.ask, null, 'ask: $reason');

  /// The one-line report for a silent box-2 run.
  String reportLine(String commandLine) =>
      '$commandLine — box 2, profile ${profile!.name} (${profile!.summary})';
}

/// Which command family one pipeline component belongs to.
enum _Family {
  /// Nothing known needs writes or network — the enforced read-only
  /// profile contains it.
  read,

  /// An interpreted script (python/node/perl): scripts profile.
  scripts,

  /// A build/test tool or file-writing command: build profile.
  build,

  /// A package fetch with a network declaration: packages profile.
  packages,

  /// Needs raw network — no box provides it.
  rawNetwork;

  BoxProfileSpec? get profile => switch (this) {
        read => null,
        scripts => boxProfileScripts,
        build => boxProfileBuild,
        packages => boxProfilePackages,
        rawNetwork => null,
      };

  int get rank => switch (this) {
        read => 0,
        scripts => 1,
        build => 2,
        packages => 3,
        rawNetwork => 4,
      };

  /// The profile that covers both families — the more permissive one.
  _Family cover(_Family other) => rank >= other.rank ? this : other;
}

/// Sorts [request] into a box. See the library comment for the rules.
BoxDecision sortBox(ProcessRequest request,
    {required BoxSortContext context}) {
  // No backend, no containment: the existing approval path owns it.
  if (!context.confined) {
    return BoxDecision.askOf(
        'no OS sandbox backend can enforce a box on this host');
  }
  if (context.outsideSandboxRequested) {
    return BoxDecision.askOf('outside-sandbox host execution');
  }

  // Parse once. A shell-string request goes through the literal shell
  // grammar (or the heredoc shape it cannot express); a plain argv request
  // — what the exec tool builds — is its own single component. Anything
  // else is an unknown construct: ask.
  final components = <({
    String program,
    List<String> arguments,
    List<({String text, String? target})> redirects,
  })>[];
  if (_shellString(request)) {
    final parts = literalShellParts(request) ?? _heredocParts(request);
    if (parts == null) {
      return BoxDecision.askOf('unrecognized shell constructs');
    }
    components.addAll([
      for (final part in parts)
        (
          program: path.basename(part.words.first),
          arguments: List<String>.of(part.words.skip(1)),
          redirects: part.redirects,
        ),
    ]);
  } else {
    components.add((
      program: path.basename(request.command),
      arguments: List<String>.of(request.arguments),
      redirects: const [],
    ));
  }

  // Destructive components are never silent — the allowlist cannot
  // override this either.
  for (final component in components) {
    final destructive = CapabilityEnvelope.componentDestructiveBecause(
        component.program, component.arguments);
    if (destructive != null) {
      return BoxDecision.askOf('destructive: $destructive');
    }
  }

  // The user's list decides first; a stored rule names the box/profile
  // matches run in.
  final line = approvalCommandText(request);
  final rule = context.allowlist?.match(line);
  if (rule != null) {
    if (rule.box == Box.readOnly) {
      return BoxDecision.readOnlyOf('allowed by pattern "${rule.pattern}"');
    }
    if (rule.box == Box.contained) {
      return BoxDecision.containedOf(
          rule.profile!, 'allowed by pattern "${rule.pattern}"');
    }
    return BoxDecision.askOf('pattern "${rule.pattern}" is stored as ask');
  }

  // Everything the command names must sit where a profile can contain it.
  final cwd = request.workingDirectory ?? context.workspaceRoot;
  String resolve(String operand) => canonicalSandboxPath(
      path.isAbsolute(operand) ? operand : path.join(cwd, operand));
  final workspace = canonicalSandboxPath(context.workspaceRoot);
  bool insideWorkspace(String target) => sandboxPathUnder(target, workspace);
  bool visible(String target) =>
      insideWorkspace(target) || context.canRead(target);

  final explicitCwd = request.workingDirectory;
  if (explicitCwd != null && !visible(canonicalSandboxPath(explicitCwd))) {
    return BoxDecision.askOf(
        'working directory outside the visible world ($explicitCwd)');
  }

  if (context.certifiedReadOnly) {
    for (final read in context.verifiedReads) {
      if (!visible(canonicalSandboxPath(read))) {
        return BoxDecision.askOf('reads outside the visible world ($read)');
      }
    }
  } else {
    for (final component in components) {
      for (final argument in component.arguments) {
        if (argument.contains('://')) {
          return BoxDecision.askOf('raw network (URL operand)');
        }
        if (!argument.startsWith('/') && !argument.contains('/')) continue;
        try {
          if (!visible(resolve(argument))) {
            return BoxDecision
                .askOf('operand outside the visible world ($argument)');
          }
        } on FileSystemException {
          return BoxDecision.askOf('operand cannot be resolved ($argument)');
        }
      }
    }
  }
  for (final directory in context.declaredReads) {
    if (!visible(canonicalSandboxPath(directory))) {
      return BoxDecision
          .askOf('declared read outside the visible world ($directory)');
    }
  }

  // What the invocation declares it must write, and where redirects land.
  var writeNeeded = false;
  for (final directory in context.declaredWrites) {
    final target = canonicalSandboxPath(directory);
    if (!insideWorkspace(target) && !context.canWrite(target)) {
      return BoxDecision
          .askOf('declared write outside the writable world ($directory)');
    }
    writeNeeded = true;
  }
  for (final component in components) {
    for (final redirect in component.redirects) {
      final target = redirect.target;
      if (target == null) continue;
      final resolved = resolve(target);
      if (!insideWorkspace(resolved) && !context.canWrite(resolved)) {
        return BoxDecision
            .askOf('redirect outside the writable world ($target)');
      }
      writeNeeded = true;
    }
  }

  // Family classification, per component. The run profile is the one that
  // covers every component; the box follows from it.
  var family = _Family.read;
  for (final component in components) {
    var componentFamily = _familyKind(component.program, component.arguments,
        networkRequested: context.networkRequested);
    // A redirect or a declared write needs a writable workspace: upgrade
    // scripts/read to build (packages already covers build).
    if (writeNeeded && componentFamily.rank < _Family.build.rank) {
      componentFamily = _Family.build;
    }
    family = family.cover(componentFamily);
  }
  if (family == _Family.rawNetwork) {
    return BoxDecision.askOf(_networkReason(components.first.program));
  }
  if (context.readOnlyRequested == true) {
    return BoxDecision.readOnlyOf('read-only access requested');
  }
  final profile = family.profile;
  if (profile == null) {
    return BoxDecision.readOnlyOf('read-only containment (default profile)');
  }
  return BoxDecision.containedOf(
      profile, _familyReason(components.first.program, profile));
}

const _interpreters = {'python3', 'python', 'node', 'nodejs', 'perl'};

bool _isInterpreter(String program) => _interpreters.contains(program);

/// The bash-tool shape: a shell with one collapsed payload argument.
bool _shellString(ProcessRequest request) =>
    request.command == '/bin/sh' &&
    request.arguments.length == 2 &&
    request.arguments.first == '-c';

/// The programs whose subcommands fetch packages. Network in the box model
/// exists only inside the packages profile.
bool _packagesFamily(String program, List<String> arguments) {
  bool pub() =>
      arguments.length >= 2 &&
      arguments.first == 'pub' &&
      {'get', 'add', 'upgrade', 'downgrade', 'remove'}.contains(arguments[1]);
  switch (program) {
    case 'dart':
    case 'flutter':
      return pub();
    case 'cargo':
      return arguments.isNotEmpty &&
          {'fetch', 'update'}.contains(arguments.first);
    case 'go':
      return arguments.length >= 2 &&
          arguments.first == 'mod' &&
          {'download', 'tidy', 'vendor'}.contains(arguments[1]);
    case 'npm':
      return arguments.isNotEmpty &&
          {'install', 'ci', 'update', 'add', 'upgrade'}
              .contains(arguments.first);
    case 'yarn':
      return arguments.isNotEmpty &&
          {'install', 'add', 'upgrade'}.contains(arguments.first);
    case 'pnpm':
      return arguments.isNotEmpty &&
          {'install', 'add', 'update'}.contains(arguments.first);
    case 'bun':
      return arguments.isNotEmpty &&
          {'install', 'add'}.contains(arguments.first);
    case 'pip':
    case 'pip3':
      return arguments.isNotEmpty &&
          {'install', 'download'}.contains(arguments.first);
    case 'python3':
    case 'python':
      return arguments.length >= 3 &&
          arguments[0] == '-m' &&
          {'pip', 'pip3'}.contains(arguments[1]) &&
          {'install', 'download'}.contains(arguments[2]);
  }
  return false;
}

/// Build and test tools: workspace read-write, no network.
const _buildPrograms = {
  'dart', 'flutter', 'cargo', 'go', 'make', 'cmake', 'ninja', 'meson',
  'gradle', 'mvn', 'npm', 'yarn', 'pnpm', 'bun', 'tsc', 'jest', 'vitest',
  'pytest', 'tox', 'rustc', 'gcc', 'cc', 'clang', 'c++', 'g++', 'ld', 'ar',
  'javac', 'kotlinc', 'swiftc', 'dotnet', 'xcodebuild', 'bazel', 'buck2',
  'deno',
};

/// General tools whose ordinary use writes files (the build profile
/// contains them); their read-only subcommands stay unlisted and land in
/// box 1.
const _writePrograms = {
  'cp', 'mv', 'ln', 'touch', 'mkdir', 'tee', 'install', 'tar', 'unzip',
  'zip', 'gzip', 'gunzip', 'xz', 'patch', 'chmod', 'chown', 'chgrp',
};

const _gitWriteSubcommands = {
  'add', 'commit', 'checkout', 'switch', 'restore', 'merge', 'rebase',
  'cherry-pick', 'reset', 'stash', 'apply', 'am', 'revert', 'mv', 'init',
  'tag', 'branch', 'submodule', 'worktree', 'bisect', 'notes', 'replace',
};

/// Programs that need raw network — no box provides it.
const _networkPrograms = {
  'curl', 'wget', 'ssh', 'scp', 'rsync', 'ping', 'nc', 'netcat', 'ftp',
  'dig', 'nslookup', 'host', 'telnet',
};

bool _needsRawNetwork(String program, List<String> arguments) {
  if (_networkPrograms.contains(program)) return true;
  if (program == 'git' &&
      arguments.isNotEmpty &&
      {'push', 'pull', 'fetch', 'clone', 'remote'}.contains(arguments.first)) {
    return true;
  }
  return false;
}

String _networkReason(String program) =>
    'raw network ($program) — no box provides network outside the packages '
    'profile';

String _familyReason(String program, BoxProfileSpec profile) =>
    '$program — contained by the ${profile.name} profile '
    '(${profile.summary})';

_Family _familyKind(String program, List<String> arguments,
    {required bool networkRequested}) {
  if (_needsRawNetwork(program, arguments)) return _Family.rawNetwork;
  if (_packagesFamily(program, arguments)) {
    // Without a network declaration the fetch runs offline from local
    // caches: the build profile (workspace writes) contains it.
    return networkRequested ? _Family.packages : _Family.build;
  }
  // A network declaration on any other family needs raw network.
  if (networkRequested) return _Family.rawNetwork;
  if (_isInterpreter(program)) return _Family.scripts;
  if (_buildPrograms.contains(program)) return _Family.build;
  if (_writePrograms.contains(program)) return _Family.build;
  if (program == 'git' &&
      arguments.isNotEmpty &&
      _gitWriteSubcommands.contains(arguments.first)) {
    return _Family.build;
  }
  if (program == 'sed' &&
      arguments.any(
          (argument) => argument == '-i' || argument.startsWith('--in-place'))) {
    return _Family.build;
  }
  return _Family.read;
}

/// The heredoc shape the literal grammar cannot express (it rejects
/// newlines): `<program> [flags] (<<|<<-)(MARKER|'MARKER'|'MARKER')` then
/// body lines ending with the marker line. The body is data to a contained
/// interpreter, so only the first line is parsed. Anything else returns
/// null and the command asks.
List<ShellCommandPart>? _heredocParts(ProcessRequest request) {
  if (request.command != '/bin/sh' ||
      request.arguments.length != 2 ||
      request.arguments.first != '-c') {
    return null;
  }
  final script = request.arguments.last;
  final newline = script.indexOf('\n');
  if (newline < 0) return null;
  final firstLine = script.substring(0, newline);

  // Quote-aware word scan of the first line. Plain words may not contain
  // shell constructs; only the heredoc marker may carry quotes.
  final words = <String>[];
  var word = StringBuffer();
  var active = false;
  var heredoc = false;
  String? quote;  for (var i = 0; i < firstLine.length; i++) {
    final character = firstLine[i];
    if (quote != null) {
      if (character == quote) {
        quote = null;
      } else if ('\u0024`\\'.contains(character)) {
        return null;
      } else {
        word.write(character);
      }
      continue;
    }
    if (character == "'" || character == '"') {
      if (!heredoc) return null; // quotes only inside the marker
      quote = character;
      continue;
    }
    if (character == ' ' || character == '\t') {
      if (active) {
        words.add(word.toString());
        word = StringBuffer();
        active = false;
      }
      continue;
    }
    if ('\u0024`<>(){}*?~#|;&'.contains(character)) {
      if (character == '<' && !active && word.isEmpty && !heredoc) {
        // The heredoc introducer begins here (`<<`, `<<-`, `<<MARKER`).
        if (i + 1 >= firstLine.length || firstLine[i + 1] != '<') return null;
        i++;
        if (i + 1 < firstLine.length && firstLine[i + 1] == '-') i++;
        heredoc = true;
        active = true;
        continue;
      }
      return null;
    }
    word.write(character);
    active = true;
  }
  if (quote != null || !heredoc || !active) return null;
  final marker = word.toString();
  if (marker.isEmpty || !RegExp(r'^[A-Za-z0-9_]+$').hasMatch(marker)) {
    return null;
  }
  if (words.isEmpty || words.first.isEmpty) return null;

  // The body must end with the marker line and nothing may follow it.
  final lines = script.substring(newline + 1).split('\n');
  var last = lines.length;
  if (last > 0 && lines[last - 1].isEmpty) last--; // final newline
  if (last == 0) return null;
  for (var index = 0; index < last; index++) {
    if (lines[index].trimLeft() == marker) {
      if (index != last - 1) return null;
      return [
        (
          words: List.unmodifiable(words),
          operator: null,
          redirects: const [],
        ),
      ];
    }
  }
  return null;
}
