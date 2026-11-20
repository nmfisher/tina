/// Test-support entry for tina_tools: the cross-leg fixtures every
/// catalog-consumer suite runs with (commit 28). Library code on
/// purpose — test directories are not importable across packages, and
/// the fixture must be reachable from plain `dart test` in every
/// consumer. Nothing here is used by production code.
library;

export 'src/testing/wasm_shaped_tools.dart';
