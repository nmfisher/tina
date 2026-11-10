/// Compiles tina_mode + tool policy into the capability document.
///
/// One compiler, two enforcement sites: the launcher writes the compiled
/// document for the wasm.dart host (`--capabilities=<path>`, enforced at
/// the mediators), and native enforcement is generated from the same
/// compiled model. Inputs are plain values - canonical paths, the launch
/// mode, the standing directory grants, command rules traced to their
/// grant ids, network domains, plugin grants, and the protected paths -
/// because this package has no `dart:io`: the callers resolve and read
/// the stores, the compiler shapes the document.
///
/// Mode shaping compiles `tina_mode.resolveAuthorization`'s table into
/// entries with the same observable outcomes:
///
/// | mode       | workspace preopen | network                  | commands                |
/// | ---------- | ----------------- | ------------------------ | ----------------------- |
/// | yolo       | rw                | allow_all                | wildcard allow          |
/// | auto       | rw                | domains + grants; ask    | rules; no match ask     |
/// | allow-edits| rw                | domains + grants; ask    | rules; no match ask     |
/// | read-only  | ro                | domains + grants; ask    | rules; no match ask     |
/// | ask        | rw                | domains + grants; ask    | rules; no match ask     |
///
/// The ask-mode workspace stays rw on purpose: WASI preopens are fixed at
/// instantiation, so an approved "Allow once" write must find the
/// workspace structurally open - the per-operation gate stays with the
/// engine, exactly like native ask mode. Read-only hard-blocks at the
/// host too, matching "blocked before remembered grants".
library;

import 'capability_document.dart';

/// Where a compiled entry came from, spelled into `origin` values the
/// host and the parity harness assert on.
final class EntryOrigins {
  EntryOrigins._();

  static const workspace = 'structural:workspace';
  static const config = 'structural:config';
  static const store = 'structural:store';
  static const readOnlySetting = 'setting:tina/tools/read_only_directories';
  static const writeSetting = 'setting:tina/tools/write_directories';
  static const homeCachesSetting = 'setting:tina/tools/home_caches';
  static const yoloWildcard = 'mode:yolo';
  static String grant(String grantId) => 'grant:$grantId';
  static String provider(String name) => 'provider:$name';
  static const flagPluginGrant = 'flag';
  static const credentialProtected = 'protected:credentials';
  static const tinaDirProtected = 'protected:tina-dir';
}

/// One command rule the compiler should embed, already traced to its
/// source (the caller maps the approvals stores into these).
final class CommandRuleInput {
  const CommandRuleInput({
    required this.pattern,
    required this.verdict,
    required this.origin,
  });

  final String pattern;
  final CommandVerdict verdict;
  final String origin;
}

/// The compiler inputs.
final class CapabilityInputs {
  const CapabilityInputs({
    required this.mode,
    required this.workspace,
    required this.configDir,
    this.storePath,
    this.readDirectories = const [],
    this.writeDirectories = const [],
    this.homeCaches = const [],
    this.rules = const [],
    this.domains = const [],
    this.pluginGrants = const [],
    this.protectedPaths = const [],
  });

  final CapabilityMode mode;

  /// Canonical workspace root.
  final String workspace;

  /// Canonical config directory (preopened as `config`; the engine reads
  /// `config/config` and persists settings through it).
  final String configDir;

  /// The session store file, when outside the workspace (inside rides the
  /// workspace preopen; the engine gets `TINA_ENGINE_STORE` instead).
  final String? storePath;

  /// Standing read grants.
  final List<String> readDirectories;

  /// Standing write grants.
  final List<String> writeDirectories;

  /// Explicitly shared home caches (read-write under workspace-write
  /// execution, read-only otherwise; structural entries).
  final List<String> homeCaches;

  /// Command rules (from the approvals stores), first match decides.
  final List<CommandRuleInput> rules;

  /// Allowed network domains (provider endpoints, remembered grants).
  final List<DomainEntry> domains;

  /// Plugin grants (config + launch flags).
  final List<PluginEntry> pluginGrants;

  /// Protected paths: credentials, the tina dir, the approvals store.
  final List<String> protectedPaths;
}

/// Compiles the inputs into a validated capability document.
CapabilityDocument compileCapabilities(CapabilityInputs inputs) {
  // Structural entries: the workspace (read-only mode opens it ro), the
  // config tree, and an out-of-workspace store - guest names fixed to
  // today's launcher output so guest path semantics do not move.
  final workspaceAccess =
      inputs.mode == CapabilityMode.readOnly ? DirAccessKind.read : DirAccessKind.write;
  final writes = <DirectoryEntry>[
    DirectoryEntry(
      path: inputs.workspace,
      guest: '.',
      origin: EntryOrigins.workspace,
    ),
    DirectoryEntry(
      path: inputs.configDir,
      guest: 'config',
      origin: EntryOrigins.config,
    ),
    if (inputs.storePath != null)
      DirectoryEntry(
        path: inputs.storePath!,
        guest: 'store',
        origin: EntryOrigins.store,
      ),
    for (var i = 0; i < inputs.homeCaches.length; i++)
      DirectoryEntry(
        path: inputs.homeCaches[i],
        guest: 'write-${i + 1}',
        origin: EntryOrigins.homeCachesSetting,
      ),
    for (var i = 0; i < inputs.writeDirectories.length; i++)
      DirectoryEntry(
        path: inputs.writeDirectories[i],
        guest: 'write-${inputs.homeCaches.length + i + 1}',
        origin: EntryOrigins.writeSetting,
      ),
  ];
  final reads = <DirectoryEntry>[
    if (inputs.mode == CapabilityMode.readOnly)
      DirectoryEntry(
        path: inputs.workspace,
        guest: '.',
        origin: EntryOrigins.workspace,
      ),
    for (var i = 0; i < inputs.readDirectories.length; i++)
      DirectoryEntry(
        path: inputs.readDirectories[i],
        guest: 'read-$i',
        origin: EntryOrigins.readOnlySetting,
      ),
  ];

  final rules = <CommandRule>[
    if (inputs.mode == CapabilityMode.yolo)
      CommandRule(
        pattern: '.*',
        verdict: CommandVerdict.allow,
        origin: EntryOrigins.yoloWildcard,
      ),
    for (final rule in inputs.rules)
      CommandRule(
        pattern: rule.pattern,
        verdict: rule.verdict,
        origin: rule.origin,
      ),
  ];

  return CapabilityDocument(
    mode: inputs.mode,
    workspace: inputs.workspace,
    readDirectories: reads,
    writeDirectories: workspaceAccess == DirAccessKind.write
        ? writes
        : writes.where((entry) => entry.guest != '.').toList(),
    allowAllDomains: inputs.mode == CapabilityMode.yolo,
    domains: inputs.domains,
    defaultVerdict: CommandVerdict.ask,
    rules: rules,
    pluginGrants: inputs.pluginGrants,
    protectedPaths: inputs.protectedPaths,
  );
}
