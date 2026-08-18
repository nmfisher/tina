// Probe a NIM (NVIDIA hosted inference) model's streaming tool-call format.
//
// Motivation: `meta/muse-glimmer-30b` produced tool calls whose *names* came
// back mangled during the environment-agent run — `ls<|message|>`,
// `bash<|message|>` (a chat-template control token glued to the name) and
// `ls.path`, `read.filePath` (argument name fused into the tool name) — which
// tina's registry correctly rejects as `unknown tool:` (see ~/.tina/tina.log).
// A single-turn request with 2 tools comes back CLEAN, so the trigger is
// something about the real run: the ~25-tool schema list and/or a multi-turn
// history containing tool results. This probe reproduces both:
//
//   dart run tool/nim_toolcall_probe.dart                      # 2 tools, 1 turn
//   dart run tool/nim_toolcall_probe.dart --full-tools         # ~20 schemas
//   dart run tool/nim_toolcall_probe.dart --turns 8            # multi-turn loop
//   dart run tool/nim_toolcall_probe.dart --full-tools --turns 8 --raw
//
// The loop answers each tool call with a canned plausible result (never
// executes anything) and continues until the model answers in plain text or
// the turn cap is hit — exactly the shape of tina's agent loop.
//
// API key resolution (first hit wins):
//   1. $NVIDIA_API_KEY
//   2. ~/.tina/config [providers.nim] api_key

import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

const defaultModel = 'meta/muse-glimmer-30b';
const baseUrl = 'https://integrate.api.nvidia.com';

// The `ls` and `bash` schemas exactly as tina registers them
// (packages/tina_engine lib/src/tools/ls_tool.dart / bash_tool.dart).
const smallTools = [
  {
    'type': 'function',
    'function': {
      'name': 'ls',
      'description':
          'List the entries of a directory: type marker (d/-/l), size, and '
          'name per line, directories first. Hidden entries are omitted '
          'unless `all` is true.',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Directory to list. Defaults to the agent cwd.',
          },
          'all': {
            'type': 'boolean',
            'description': 'Include hidden (dot) entries. Default false.',
          },
        },
        'required': [],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'bash',
      'description':
          'Run a shell command via /bin/sh -c. Captures stdout, stderr, '
          'and exit code. Subject to the session permission policy. Each call '
          'is a fresh shell — chain dependent steps with `&&`.',
      'parameters': {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'The shell command to run.',
          },
        },
        'required': ['command'],
      },
    },
  },
];

// Approximation of the full surface tina's main/environment agent sends:
// the 12 base tools plus the orchestration extras. Descriptions are
// abbreviated but the NAME SET and schema COUNT match the real run, which is
// what stresses the model's function-calling template.
final fullTools = [
  ...smallTools,
  _fn('read', 'Read a file from the project.', {'path': 'string'}),
  _fn('write', 'Write a file, creating or replacing it.',
      {'path': 'string', 'content': 'string'}),
  _fn('edit', 'Replace a span of text in an existing file.',
      {'path': 'string', 'oldText': 'string', 'newText': 'string'}),
  _fn('fetch', 'Fetch a URL and return the page as text.', {'url': 'string'}),
  _fn('search', 'Semantic search over the project.', {'query': 'string'}),
  _fn('grep', 'Regex search over file contents.',
      {'pattern': 'string', 'path': 'string'}),
  _fn('glob', 'List files matching a glob pattern.',
      {'pattern': 'string', 'path': 'string'}),
  _fn('stat', 'Stat a file or directory: size, times, type.',
      {'path': 'string'}),
  _fn('which', 'Resolve an executable on PATH.', {'name': 'string'}),
  _fn('git', 'Read-only git queries: log, status, diff, show.',
      {'args': 'string'}),
  _fn('delegate', 'Delegate a focused sub-task to a sub-agent.',
      {'task': 'string', 'tools': 'string'}),
  _fn('render_image', 'Render a local image file into the panel.',
      {'path': 'string'}),
  _fn('ask_user', 'Pose a multiple-choice question to the user.',
      {'questions': 'string'}),
  _fn('launch_workflow', 'Launch a DOT workflow in the background.',
      {'input': 'string'}),
  _fn('stop_workflow', 'Stop a running workflow.', {'runId': 'string'}),
  _fn('web_search', 'Search the web.', {'query': 'string'}),
];

Map<String, Object> _fn(String name, String desc, Map<String, String> props) => {
      'type': 'function',
      'function': {
        'name': name,
        'description': desc,
        'parameters': {
          'type': 'object',
          'properties': {
            for (final e in props.entries)
              e.key: {'type': e.value, 'description': '${e.key} parameter.'},
          },
          'required': props.keys.toList(),
        },
      },
    };

// Shaped like the environment agent's identity (lib/environment/
// environment_runner.dart) — the run where the mangling showed up.
const systemPrompt = 'You are the environment agent for this repository. '
    'Your job is to establish the environment: dependencies installed, '
    'toolchain present, build and test commands known and working. '
    'You are a doing worker — you run commands, you do not just describe '
    'them. Use bash for commands and write/edit for the record.';

// The REAL environment-agent identity, verbatim from
// lib/environment/environment_runner.dart `_identity` — used by --real.
const realIdentity = '''
You are the environment agent for this repository. Your job is to establish and maintain the environment every agent here needs: dependencies installed, toolchain present, build and test commands known and working, git identity and GitHub auth configured. You are a doing worker — you run commands, you do not just describe them.

The repo's environment record is ENVIRONMENT.md at the repo root. It has two kinds of content: intent sections (Toolchain, Setup, Build, Test, Auth — the commands that should be run) and observed sections (the test baseline, "verified at" stamps — what the last run measured). The user may edit anything; treat the intent sections as authoritative and rewrite only the observed sections from your own fresh measurements.

Rules:
- Run the setup: dependency install, build, test. Use bash for commands and write/edit for the record.
- Measure before you claim: run the test suite and record what actually happened (counts, failures). Never invent a baseline.
- Auth entries are references only — never write tokens, passwords, or key material into the record. You may check auth (gh auth status, git config) and load keys (ssh-add); if something needs a typed secret, record "needs user action" instead.
- If a dependency step, command, or tool is missing, add or fix it in the intent sections and note what you changed.
- Delegate read-only exploration (reading manifests, checking the toolchain) to sub-agents when useful; keep the mutating actions to yourself.

Finish with a short report: what you ran, what passed, what failed, what needs user action.''';

// The REAL first-load task prompt, verbatim from environment_runner.dart
// `_taskPrompt` (project root substituted).
String realTaskPrompt(String project) =>
    'No ENVIRONMENT.md exists at $project yet. Populate it from '
    'measurements: inspect the dependency manifests and toolchain, run '
    'the setup, build, and tests, check git identity / SSH key / GitHub '
    'auth, then write ENVIRONMENT.md with the intent sections (Setup, '
    'Build, Test, Auth references) and the observed sections (Toolchain '
    'observed, Test baseline with real counts, verified-at stamp with '
    'the current commit).';

// The REAL tool schemas tina sends, via the engine's buildTools() — exact
// names, full-length descriptions, the real input shapes. Encoded the same
// way OpenAiCompatibleAdapter._encodeTool does.
List<Map<String, Object>> realTools() => [
      for (final t in buildTools().all)
        {
          'type': 'function',
          'function': {
            'name': t.schema.name,
            'description': t.schema.description,
            'parameters': t.schema.inputSchema,
          },
        },
    ];


const userPrompt =
    'Inspect the current directory and report what kind of project it is. '
    'List the top-level entries first.';

Future<void> main(List<String> args) async {
  var model = defaultModel;
  var turns = 1;
  var fullTools_ = false;
  var real = false;
  var realTools_ = false;
  var realPrompts = false;
  var raw = false;
  for (final a in args) {
    if (a == '--full-tools') {
      fullTools_ = true;
    } else if (a == '--real') {
      real = true;
    } else if (a == '--real-tools') {
      realTools_ = true;
    } else if (a == '--real-prompts') {
      realPrompts = true;
    } else if (a == '--raw') {
      raw = true;
    } else if (a.startsWith('--turns=')) {
      turns = int.tryParse(a.substring(8)) ?? turns;
    } else if (!a.startsWith('--')) {
      model = a;
    }
  }
  // --real sets both halves; --real-tools / --real-prompts bisect which half
  // triggers the mangling.
  final useRealTools = real || realTools_;
  final useRealPrompts = real || realPrompts;
  final tools = useRealTools
      ? realTools()
      : fullTools_
          ? fullTools
          : smallTools;
  final system = useRealPrompts ? realIdentity : systemPrompt;
  final task = useRealPrompts
      ? realTaskPrompt(Directory.current.path)
      : userPrompt;

  final key = _resolveApiKey();
  if (key == null || key.isEmpty) {
    stderr.writeln('no API key: set NVIDIA_API_KEY or put api_key under '
        '[providers.nim] in ~/.tina/config');
    exitCode = 1;
    return;
  }

  stdout
    ..writeln('model  : $model')
    ..writeln('turns  : $turns')
    ..writeln('real   : $real')
    ..writeln('tools  : ${[
      for (final t in tools) (t['function'] as Map)['name'],
    ].join(', ')}');

  final messages = <Map<String, Object>>[
    {'role': 'system', 'content': system},
    {'role': 'user', 'content': task},
  ];

  final client = HttpClient();
  var mangled = 0;
  try {
    for (var turn = 1; turn <= turns; turn++) {
      final result = await _request(client, key, model, tools, messages,
          raw: raw && turn == 1);
      stdout.writeln('--- turn $turn ---');
      stdout.writeln('  finish_reason : ${result.finishReason}');
      if (result.text.isNotEmpty) {
        stdout.writeln('  text          : ${_visible(result.text)}');
      }
      if (result.toolCalls.isEmpty) {
        stdout.writeln('  tool_calls    : (none) — model finished in prose');
        break;
      }
      messages.add({
        'role': 'assistant',
        'content': result.text,
        'tool_calls': [
          for (final pc in result.toolCalls)
            {
              'id': pc.id ?? 'call_${result.toolCalls.indexOf(pc)}',
              'type': 'function',
              'function': {
                'name': pc.name ?? '',
                'arguments': pc.args.toString(),
              },
            },
        ],
      });
      for (final pc in result.toolCalls) {
        final clean = _trimName(pc.name);
        final bad = clean != (pc.name ?? '');
        if (bad) mangled++;
        stdout.writeln('  tool_call     : raw name = '
            '${_visible(pc.name ?? '(null)')}'
            '${bad ? '  <-- MANGLED (would be `unknown tool` in tina; '
                'intended: $clean)' : ''}');
        stdout.writeln('    arguments   : ${pc.args}');
        messages.add({
          'role': 'tool',
          'tool_call_id': pc.id ?? 'call_${result.toolCalls.indexOf(pc)}',
          'content': _cannedResult(clean),
        });
      }
      if (turn == turns) {
        stdout.writeln('(turn cap reached)');
      }
    }
    stdout.writeln('---');
    stdout.writeln(mangled == 0
        ? 'no mangled names observed this run'
        : '$mangled mangled tool name(s) observed — reproduce of the '
            '`unknown tool:` failures in tina');
  } finally {
    client.close(force: true);
  }
}

Future<_TurnResult> _request(HttpClient client, String key, String model,
    List<Map<String, Object>> tools, List<Map<String, Object>> messages,
    {required bool raw}) async {
  final req = await client.postUrl(Uri.parse('$baseUrl/v1/chat/completions'))
    ..headers.set('Authorization', 'Bearer $key')
    ..headers.contentType = ContentType.json;
  req.write(jsonEncode({
    'model': model,
    'stream': true,
    'messages': messages,
    'tools': tools,
  }));
  final resp = await req.close();
  if (resp.statusCode != 200) {
    stderr.writeln('HTTP ${resp.statusCode}:');
    stderr.writeln(await resp.transform(utf8.decoder).join());
    exitCode = 1;
    return _TurnResult('http-error', '', const []);
  }

  // Mirror tina's accumulation (openai_compatible.dart): per-index partial
  // calls, first non-null name wins, arguments concatenated across deltas.
  final toolCalls = <int, _PartialCall>{};
  final text = StringBuffer();
  var finishReason = 'stop';
  final lines =
      resp.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.isEmpty || !line.startsWith('data:')) continue;
    if (raw) stdout.writeln('RAW $line');
    final payload = line.substring(5).trim();
    if (payload == '[DONE]') continue;
    final Map<String, dynamic> evt;
    try {
      evt = jsonDecode(payload) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    final choices = evt['choices'] as List?;
    if (choices == null || choices.isEmpty) continue;
    final choice = choices.first as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>?;
    if (delta != null) {
      final c = delta['content'];
      if (c is String && c.isNotEmpty) text.write(c);
      final tc = delta['tool_calls'] as List?;
      if (tc != null) {
        for (final t in tc) {
          final tm = t as Map<String, dynamic>;
          final idx = (tm['index'] as int?) ?? 0;
          final partial = toolCalls.putIfAbsent(idx, _PartialCall.new);
          final id = tm['id'];
          if (id is String) partial.id ??= id;
          final fn = tm['function'] as Map<String, dynamic>?;
          if (fn != null) {
            final n = fn['name'];
            if (n is String && partial.name == null) partial.name = n;
            final a = fn['arguments'];
            if (a is String) partial.args.write(a);
          }
        }
      }
    }
    final fr = choice['finish_reason'];
    if (fr is String) finishReason = fr;
  }
  final indices = toolCalls.keys.toList()..sort();
  return _TurnResult(
      finishReason, text.toString(), [for (final i in indices) toolCalls[i]!]);
}

/// The known mangling modes, applied the way a defensive registry lookup
/// could: strip chat-template control tokens and a trailing `.argumentName`
/// fragment. Tina's own tool names contain neither.
String _trimName(String? raw) {
  var name = raw ?? '';
  // Template control tokens: <|message|>, <|tool_call|>, <|end|>, …
  name = name.replaceAll(RegExp(r'<\|[^|]*\|>'), '');
  // Argument-name fusion: "ls.path", "read.filePath" — tina tool names never
  // contain a dot, so the first segment is the intended tool.
  if (name.contains('.')) name = name.split('.').first;
  return name.trim();
}

/// A plausible canned answer per tool, so the conversation history looks like
/// a real agent loop to the model. Nothing is ever executed.
String _cannedResult(String tool) {
  switch (tool) {
    case 'ls':
      return 'd         -  .dart_tool\n'
          'd         -  .git\n'
          '-      1234  AGENTS.md\n'
          '-       512  pubspec.yaml\n'
          'd         -  lib\n'
          'd         -  packages\n'
          'd         -  test\n'
          'd         -  tool';
    case 'bash':
      return '\$ dart --version\n'
          'Dart SDK version: 3.9.0 (stable)\n'
          'exit code 0';
    case 'read':
      return 'name: tina\ndescription: A coding agent TUI.\n';
    case 'grep':
    case 'search':
    case 'glob':
      return 'lib/main.dart\nlib/config.dart';
    case 'stat':
      return 'type: file, size: 1024';
    case 'which':
      return '/opt/homebrew/bin/dart';
    case 'git':
      return '## main...origin/main\n M lib/tui_coordinator.dart';
    case 'fetch':
    case 'web_search':
      return '(200 OK, 1500 chars of page text)';
    default:
      return '(ok)';
  }
}

/// Make control characters visible: escape \n \r \t.
String _visible(String s) =>
    s.replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t');

String? _resolveApiKey() {
  final env = Platform.environment['NVIDIA_API_KEY'];
  if (env != null && env.isNotEmpty) return env;
  final file = File(
      Uri.parse('${Platform.environment['HOME']}/.tina/config').toFilePath());
  if (!file.existsSync()) return null;
  var inNim = false;
  for (final line in file.readAsLinesSync()) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inNim = t.startsWith('[providers.nim]');
      continue;
    }
    if (inNim) {
      final m =
          RegExp(r"""^api_key\s*=\s*['"]?([^'"\s#]+)""").firstMatch(t);
      if (m != null) return m.group(1);
    }
  }
  return null;
}

class _PartialCall {
  String? id;
  String? name;
  final args = StringBuffer();
}

class _TurnResult {
  final String finishReason;
  final String text;
  final List<_PartialCall> toolCalls;
  _TurnResult(this.finishReason, this.text, this.toolCalls);
}
