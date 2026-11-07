/// The provider defaults that need `dart:io`-backed implementations: the
/// unnamed wire's HTTP endpoint. Split out (stage 5, engine-on-wasm) so
/// the provider construction path compiles under wasm, where a
/// composition root injects the endpoint over `tina:http` instead.
library;

import 'package:tina_llm/tina_llm.dart';

import 'provider_default_stub.dart' if (dart.library.io) 'provider_default_io.dart';

/// The HTTP endpoint for the unnamed provider wire at [base]: the native
/// `tina_io` client where `dart:io` exists. A wasm composition root
/// supplies its own endpoint and never calls this.
HttpEndpoint defaultHttpEndpoint(String base) => nativeHttpEndpoint(base);
