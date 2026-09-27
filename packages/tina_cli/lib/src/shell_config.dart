/// Reading `~/.tina/config` — the same file and shape tina uses today:
/// `version = 1` and a `[default]` section with an optional `provider`
/// and a `model`. No new format, and never a token: the file carries no
/// credentials (endpoint and token come from the environment, which
/// `tina_llm` already reads), so there is nothing here to keep secret —
/// but nothing here prints the environment either.
///
/// The resolution rules are the old engine's: a `provider/model` model
/// reference overrides the section's provider; a bare model with a
/// `[default] provider` names that provider's model; a bare model with no
/// provider rides the Anthropic wire (the sandbox endpoint speaks it, and
/// `AnthropicProvider` reads `TINA_LLM_ENDPOINT` itself).
library;

import 'dart:io' show File, Platform;

import 'package:tina_llm/tina_llm.dart';

/// The schema version this shell understands. The file declares its
/// version with a top-level `version = N`; a reader that finds another
/// version refuses the file rather than guessing.
const int kShellConfigVersion = 1;

/// Where tina's config lives today.
const String kShellConfigPath = '.tina/config';

/// The model this shell runs when the file is missing or has no model:
/// the scripted provider's label, so a bare `dart run` in a test or a
/// fresh checkout does something well-defined instead of erroring.
const String kShellDefaultModel = 'scripted';

/// The parsed `~/.tina/config`, narrowed to what the shell needs.
final class ShellConfig {
  const ShellConfig({this.providerId, required this.model});

  /// The provider id from the config — null when the file did not name
  /// one, which sends a bare model down the Anthropic wire.
  final String? providerId;

  /// The model label the provider will be built with.
  final String model;
}

/// How reading the config went: [config] on success, [problem] when the
/// file exists but cannot be honored. A missing file is a *success* with
/// the default model — a fresh checkout must run, not nag.
sealed class ShellConfigResult {
  const ShellConfigResult();

  ShellConfig get config => switch (this) {
        ShellConfigOk(:final resolved) => resolved,
        ShellConfigProblem(:final resolved) => resolved,
      };
}

/// The file was read (or was absent) and a model was resolved.
final class ShellConfigOk extends ShellConfigResult {
  const ShellConfigOk(this.resolved, {this.path});

  final ShellConfig resolved;

  /// The file that was read; null when the config file was absent.
  final String? path;

  /// One status line for the shell's banner, e.g.
  /// `config: ~/.tina/config — glm/glm-5.3-flashx`. Null when defaults
  /// were used.
  String? get note => path == null
      ? null
      : 'config: $path — '
          '${config.providerId == null ? 'anthropic wire' : config.providerId}'
          '/${config.model}';
}

/// The file exists but cannot be honored: bad syntax, wrong version, or
/// no model anywhere. [config] carries the fallback the shell will run
/// with; [problem] is printed once, to the writer, and the shell keeps
/// going — a broken config must not take the session down.
final class ShellConfigProblem extends ShellConfigResult {
  const ShellConfigProblem(this.problem, this.resolved);

  final String problem;

  final ShellConfig resolved;

  /// One status line for the shell's banner.
  String get note => 'config: $problem — falling back to '
      '${config.providerId == null ? 'the anthropic wire' : config.providerId}'
      '/${config.model}';
}

/// Read and parse the config file at [path] (default `~/.tina/config`),
/// resolving the model reference against [descriptors]. Pure and offline:
/// one file read, string work, one list scan.
ShellConfigResult loadShellConfig({
  String? path,
  List<ProviderDescriptor> descriptors = builtinDescriptors,
  Map<String, String> environment = const {},
}) {
  final file = File(path ?? _defaultPath(environment));
  if (!file.existsSync()) {
    return const ShellConfigOk(ShellConfig(model: kShellDefaultModel));
  }
  final String text;
  try {
    text = file.readAsStringSync();
  } catch (e) {
    return ShellConfigProblem(
        'cannot read $file: $e', const ShellConfig(model: kShellDefaultModel));
  }
  final parsed = _parseTomlSubset(text);
  final ShellConfig? bad;
  if (parsed == null) {
    bad = const ShellConfig(model: kShellDefaultModel);
    return ShellConfigProblem(
        '$file is not valid config syntax', bad);
  }
  final version = parsed['version'];
  if (version != null && version != kShellConfigVersion) {
    return ShellConfigProblem(
        '$file is config version $version; this shell understands '
        'version $kShellConfigVersion',
        const ShellConfig(model: kShellDefaultModel));
  }
  final section = parsed['default'];
  if (section is! Map<String, dynamic>) {
    return ShellConfigProblem(
        '$file has no [default] section',
        const ShellConfig(model: kShellDefaultModel));
  }
  final provider = section['provider'];
  if (provider != null && provider is! String) {
    return ShellConfigProblem('$file: [default] provider must be a string',
        const ShellConfig(model: kShellDefaultModel));
  }
  final model = section['model'];
  if (model is! String || model.isEmpty) {
    return ShellConfigProblem(
        '$file has no [default] model',
        ShellConfig(providerId: provider as String?, model: kShellDefaultModel));
  }
  // `provider/model` in the model wins over the section's provider — the
  // old engine's rule, so a config written for tina reads the same here.
  var providerId = provider as String?;
  var modelId = model;
  final slash = model.indexOf('/');
  if (slash > 0) {
    providerId = model.substring(0, slash);
    modelId = model.substring(slash + 1);
  }
  if (providerId != null && descriptorByIdFor(providerId, descriptors) == null) {
    return ShellConfigProblem(
        '$file: unknown provider "$providerId"',
        ShellConfig(model: modelId));
  }
  return ShellConfigOk(ShellConfig(providerId: providerId, model: modelId),
      path: file.path);
}

/// The model reference the way the old engine prints it: `provider/model`
/// when a provider is named, the bare model when the anthropic wire is
/// implied. This is the label [HostConfig.model] carries and the factory
/// receives.
String shellModelReference(ShellConfig config) => config.providerId == null
    ? config.model
    : '${config.providerId}/${config.model}';

/// Look one descriptor up by id among [descriptors].
ProviderDescriptor? descriptorByIdFor(
    String id, List<ProviderDescriptor> descriptors) {
  for (final d in descriptors) {
    if (d.id == id) return d;
  }
  return null;
}

String _defaultPath(Map<String, String> environment) {
  final home = environment['HOME'] ??
      (() {
        try {
          return Platform.environment['HOME'];
        } catch (_) {
          return null;
        }
      })();
  if (home == null || home.isEmpty) return kShellConfigPath;
  return '$home/$kShellConfigPath';
}

/// The config syntax in use is a small TOML subset — top-level
/// `key = value` and one-level `[table]` sections with string, integer
/// and boolean values, `#` comments, basic and literal strings. That is
/// all `~/.tina/config` uses (tina's writer emits exactly this), and
/// parsing it here keeps tina_cli free of a parser dependency the four
/// packages do not bring. Anything the subset cannot read is reported as
/// a problem, never half-interpreted.
Map<String, dynamic>? _parseTomlSubset(String text) {
  final root = <String, dynamic>{};
  var section = root;
  for (final rawLine in text.split('\n')) {
    var line = rawLine.trim();
    final hash = line.indexOf('#');
    if (hash == 0) continue;
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      if (!line.endsWith(']')) return null;
      final name = line.substring(1, line.length - 1).trim();
      if (name.isEmpty ||
          name.contains('[') ||
          name.contains(']') ||
          name.contains('.')) {
        return null;
      }
      final next = <String, dynamic>{};
      root[name] = next;
      section = next;
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) return null;
    final key = line.substring(0, eq).trim();
    if (key.isEmpty) return null;
    final valueText = line.substring(eq + 1).trim();
    final (:value, :ok) = _parseValue(valueText);
    if (!ok) return null;
    section[key] = value;
  }
  return root;
}

/// One config value: [ok] false means the text is not in the subset.
({Object? value, bool ok}) _parseValue(String text) {
  if (text.isEmpty) return (value: null, ok: false);
  if (text.startsWith('"')) {
    if (text.length < 2 || !text.endsWith('"')) return (value: null, ok: false);
    final body = text.substring(1, text.length - 1);
    final buf = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (c != r'\') {
        buf.write(c);
        continue;
      }
      if (i + 1 >= body.length) return (value: null, ok: false);
      final n = body[++i];
      final String decoded;
      switch (n) {
        case 'n':
          decoded = '\n';
        case 't':
          decoded = '\t';
        case 'r':
          decoded = '\r';
        case '"':
          decoded = '"';
        case r'\':
          decoded = r'\';
        default:
          return (value: null, ok: false);
      }
      buf.write(decoded);
    }
    return (value: buf.toString(), ok: true);
  }
  if (text.startsWith("'")) {
    if (text.length < 2 || !text.endsWith("'")) return (value: null, ok: false);
    return (value: text.substring(1, text.length - 1), ok: true);
  }
  if (text == 'true' || text == 'false') return (value: text, ok: true);
  final asInt = int.tryParse(text);
  if (asInt != null) return (value: asInt, ok: true);
  return (value: null, ok: false);
}
