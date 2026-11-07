import 'package:tina_llm/tina_llm.dart';

/// The no-`dart:io` endpoint default: a wasm composition root injects
/// its own endpoint over `tina:http`; reaching this default there is a
/// wiring bug.
HttpEndpoint nativeHttpEndpoint(String base) => throw UnsupportedError(
    'no default HTTP endpoint on this platform: inject one over tina:http');
