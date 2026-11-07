/// The native port implementations: `dart:io` wrapped behind tina_core's
/// I/O ports. Engine packages never import this — the composition root
/// constructs these and injects them (native behavior), and a wasm build
/// supplies different implementations of the same ports.
library;

export 'src/io_http_endpoint.dart';
export 'src/io_file_system_port.dart';
export 'src/io_environment_port.dart';
