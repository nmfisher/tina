// ignore_for_file: type=warning
/// The `tina:policy` host interface: the escalation channel of the
/// capability merger (`docs/capability_merger.md`).
///
/// The engine compiles the capability document and the host enforces it.
/// When an approval flow grants more than one call - an "always" or
/// scoped answer - the engine persists the grant through its own stores
/// and calls `widen` here so the host's live policy covers later calls
/// without re-asking. Entries are validated fail-closed (patterns
/// compile, directories exist, protected paths are never covered); a
/// widened directory is recorded for the engine's gating but cannot add a
/// preopen - those are fixed at instantiation and take effect on the next
/// launch.
///
/// `snapshot` exposes the effective document (launch entries plus
/// widenings) for diagnostics and parity assertions.
library;

import r'package:wasm_components/wasm_components.dart' as i0;

abstract interface class Types {}

/// The access class of a directory grant.
enum TypesDirectoryAccess { read, write }

/// How one command rule judges a command line.
enum TypesVerdict { allow, deny, ask }

/// One widening or launch entry.
sealed class TypesCapabilityEntry {
  const TypesCapabilityEntry._();
  const factory TypesCapabilityEntry.directory(
    ({String path, TypesDirectoryAccess access, String origin}) payload,
  ) = TypesCapabilityEntryDirectory;
  const factory TypesCapabilityEntry.domain(
    ({String domain, String origin}) payload,
  ) = TypesCapabilityEntryDomain;
  const factory TypesCapabilityEntry.command(
    ({String pattern, TypesVerdict verdict, String origin}) payload,
  ) = TypesCapabilityEntryCommand;
  const factory TypesCapabilityEntry.plugin(
    ({String plugin, List<String> grants, String origin}) payload,
  ) = TypesCapabilityEntryPlugin;
  const factory TypesCapabilityEntry.protected(String payload) =
      TypesCapabilityEntryProtected;
}

final class TypesCapabilityEntryDirectory extends TypesCapabilityEntry {
  final ({String path, TypesDirectoryAccess access, String origin}) payload;
  const TypesCapabilityEntryDirectory(this.payload) : super._();
}

final class TypesCapabilityEntryDomain extends TypesCapabilityEntry {
  final ({String domain, String origin}) payload;
  const TypesCapabilityEntryDomain(this.payload) : super._();
}

final class TypesCapabilityEntryCommand extends TypesCapabilityEntry {
  final ({String pattern, TypesVerdict verdict, String origin}) payload;
  const TypesCapabilityEntryCommand(this.payload) : super._();
}

final class TypesCapabilityEntryPlugin extends TypesCapabilityEntry {
  final ({String plugin, List<String> grants, String origin}) payload;
  const TypesCapabilityEntryPlugin(this.payload) : super._();
}

final class TypesCapabilityEntryProtected extends TypesCapabilityEntry {
  final String payload;
  const TypesCapabilityEntryProtected(this.payload) : super._();
}

abstract interface class Policy {
  /// Widen the live policy with one entry after an approved escalation.
  /// Validated fail-closed; the error carries the refusal. The engine
  /// persists the grant itself - the host's widening is memory for this
  /// run only.
  Future<i0.Result<void, String>> widen({required TypesCapabilityEntry entry});

  /// The effective document for diagnostics and parity assertions.
  ({
    String mode,
    List<TypesCapabilityEntry> entries,
    List<String> protectedPaths,
  })
  snapshot();
}
