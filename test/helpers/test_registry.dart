import 'package:tina_engine/tina_engine.dart';

/// A [ProviderRegistry] built from [env] with all built-in providers registered.
///
/// This mirrors what production code does, but constructed from the same env
/// the test injects so there is no [Platform.environment] leakage.
ProviderRegistry testRegistry(Map<String, String> env) {
  final r = ProviderRegistry(env: env);
  registerBuiltins(r);
  return r;
}
