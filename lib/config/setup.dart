import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'user_config.dart';

/// Assemble a [UserConfig] from collected setup answers — shared by the stdin
/// wizard ([runSetupWizard]) and the TUI overlay form. [keys] maps provider id
/// → api key. The default provider/model come from the explicit args (the model
/// the user picked as the default). [limits] (the `/settings` path only) is
/// written to the `[limits]` table; null omits it so first-run keeps the
/// shipped defaults.
UserConfig buildSetupConfig({
  required Map<String, String> keys,
  String? defaultProvider,
  String? defaultModel,
  LimitsConfig? limits,

  /// Existing provider configs from the current ~/.tina/config. The settings
  /// overlay passes these so hand-edited fields like `base_url`, `wire`, and
  /// `name` survive a re-save. For each provider id in [keys], the new
  /// `apiKey` wins; the existing config's `baseUrl`, `authToken`, `wire`, and
  /// `name` are carried forward when not overridden. Unused in the first-run
  /// stdin wizard (no existing config).
  Map<String, ProviderConfig>? existingProviders,

  /// Base URLs explicitly entered by the user in `/settings`. Maps provider id
  /// to a URL string (or empty to clear). When a provider's id is present in
  /// this map, its value wins over [existingProviders]; when absent, the
  /// existing config's base URL (if any) survives. This lets the user both
  /// set and clear a custom endpoint from the overlay.
  Map<String, String>? baseUrls,

  /// Models the user explicitly disabled per provider. Maps provider id to a
  /// set of model ids that are checked but disabled for `/spawn`. Applied
  /// after carrying forward existing config, so a re-save preserves unchecking.
  Map<String, Set<String>>? disabledModels,

  /// Named theme variant: `"dark"` or `"light"`. Null means "system / default"
  /// (no [theme] variant written). Written to `[theme] variant` in the TOML
  /// and resolved to a built-in [Theme] preset at startup.
  String? themeVariant,
}) {
  String? resolvedBaseUrl(String id) {
    if (baseUrls?.containsKey(id) == true) {
      final v = baseUrls![id]!;
      return v.isEmpty ? null : v;
    }
    return existingProviders?[id]?.baseUrl;
  }

  return UserConfig(
    defaultProvider: defaultProvider,
    defaultModel: defaultModel,
    providers: {
      for (final id in keys.keys)
        id: ProviderConfig(
          apiKey: keys[id],
          baseUrl: resolvedBaseUrl(id),
          authToken: existingProviders?[id]?.authToken,
          wire: existingProviders?[id]?.wire,
          name: existingProviders?[id]?.name,
          models: existingProviders?[id]?.models,
          disabledModels: disabledModels?[id],
        ),
    },
    limits: limits,
    themeVariant: themeVariant,
  );
}

/// Run the first-run setup wizard. Prompt for a default provider and model,
/// collecting the provider's API key (skipped for auth-optional providers like
/// local servers). Writes `~/.tina/config` (chmod 600) and returns true; returns
/// false if the user skipped or declined the confirm (nothing written).
///
/// Never throws — an empty answer or EOF at any prompt skips/cancels. [prompt]
/// defaults to `stdout.write` + `stdin.readLineSync`; tests inject a queued
/// callback. [tinaDir] is injectable for tests.
bool runSetupWizard({
  required Map<String, String> env,
  required ProviderRegistry registry,
  Directory? tinaDir,
  String? Function(String)? prompt,
}) {
  final ask = prompt ?? _stdinPrompt;
  stdout.writeln('No ~/.tina/config found — this sets up a default '
      'provider/model so launches become zero-arg.');
  stdout.writeln('Press Enter to skip a prompt, Ctrl-C to cancel.\n');

  final providerIds = registry.providerIds;
  final keys = <String, String>{}; // provider id → api key
  String? defaultProvider;
  String? defaultModel;

  final provider = _pick(ask, 'Default provider', providerIds);
  if (provider == null) {
    stdout.writeln('  (skipped — no default provider chosen)\n');
    return false;
  }
  final modelOptions = registry.modelsFor(provider).map((m) => m.id).toList();
  final model =
      _pick(ask, 'Default model for $provider', modelOptions, allowArbitrary: true);
  if (model == null) {
    stdout.writeln('  (skipped — no default model chosen)\n');
    return false;
  }
  defaultProvider = provider;
  defaultModel = model;
  // Collect the key unless auth is optional.
  final desc = registry.descriptor(provider);
  if (desc != null && !registry.isAuthOptional(desc)) {
    final key = ask('API key for $provider: ');
    if (key != null && key.isNotEmpty) keys[provider] = key;
  }
  stdout.writeln('');

  stdout.writeln('Writing ~/.tina/config:');
  stdout.writeln('  [default] $defaultProvider/$defaultModel');
  for (final id in keys.keys) {
    stdout.writeln('  [providers.$id] api_key = '
        '${keys[id]!.isEmpty ? "" : "…"}');
  }
  final confirm = ask('Write this config? [Y/n] ');
  if (confirm != null && confirm.trim().toLowerCase() == 'n') {
    stdout.writeln('Cancelled; nothing written.');
    return false;
  }

  final path;
  try {
    path = writeUserConfig(
      buildSetupConfig(
        keys: keys,
        defaultProvider: defaultProvider,
        defaultModel: defaultModel,
      ),
      env: env,
      tinaDir: tinaDir,
    );
  } on ConfigWriteException catch (e) {
    stderr.writeln('error: $e');
    stderr.writeln('       (is the config on a read-only mount? '
        'e.g. the sandbox binds ~/.tina/config as :ro)');
    return false;
  }
  stdout.writeln('Wrote $path');
  return true;
}

String? _stdinPrompt(String prompt) {
  stdout.write(prompt);
  return stdin.readLineSync();
}

/// Prompt with a numbered menu plus a free-text fallback. Returns the chosen
/// value, or null to skip (empty input / EOF). With [allowArbitrary], any
/// non-empty input is accepted (the menu is just a suggestion); otherwise an
/// unknown value re-prompts. Typing a known option's text verbatim also works.
String? _pick(
  String? Function(String) ask,
  String label,
  List<String> options, {
  bool allowArbitrary = false,
}) {
  while (true) {
    final buf = StringBuffer(label);
    for (var i = 0; i < options.length; i++) {
      buf.write('\n  ${i + 1}. ${options[i]}');
    }
    buf.write('\n> ');
    final raw = ask(buf.toString());
    if (raw == null) return null; // EOF / cancel
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null; // skip
    final n = int.tryParse(trimmed);
    if (n != null && n >= 1 && n <= options.length) return options[n - 1];
    if (allowArbitrary) return trimmed;
    if (options.contains(trimmed)) return trimmed;
    stdout.writeln('  "$trimmed" is not an option; try again, or Enter to skip.');
  }
}
