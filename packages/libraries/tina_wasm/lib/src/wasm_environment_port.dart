/// The wasm environment port: `tina_core`'s [EnvironmentPort] over
/// `wasi:cli/environment` - the variables the host declared for the
/// component and its initial working directory.
library;

import 'package:tina_core/tina_core.dart';

import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;

/// [EnvironmentPort] over WASI. The environment is fixed at instantiation
/// by the host (a component cannot see the host's process environment
/// beyond what was granted), so lookups replay the same table - exactly
/// the "morally a value import" contract `get-environment` documents.
final class WasmEnvironmentPort implements EnvironmentPort {
  WasmEnvironmentPort(this._environment);

  final wasi_cli.Environment _environment;

  List<(String, String)>? _cached;

  @override
  String? env(String name) {
    final table = _cached ??= _environment.getEnvironment();
    for (final (key, value) in table) {
      if (key == name) return value;
    }
    return null;
  }

  @override
  String get currentDirectory {
    // The initial cwd the host declared; '.' is the shorthand for it.
    final cwd = _environment.getInitialCwd();
    if (cwd.hasValue) {
      final path = cwd.requireValue();
      if (path.isNotEmpty) return path;
    }
    return '.';
  }
}
