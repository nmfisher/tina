/// The static-first plugin registry client: fetch, verify, consent, cache.
///
/// Mirrors `tools/plugin-registry` (the publisher) so the two sides stay
/// honest against each other. The trust model: sha256 integrity + a
/// detached ed25519 signature over canonical entry JSON against a key
/// pinned in the client config + manifest consent (design doc section 4).
/// The registry adds provenance, not permission.
library tina_plugin_registry;

export 'src/abi_stamp.dart';
export 'src/canonical_json.dart';
export 'src/consent.dart';
export 'src/entry.dart';
export 'src/install.dart';
export 'src/plugin_cache.dart';
export 'src/registry_client.dart';
export 'src/signature.dart';
