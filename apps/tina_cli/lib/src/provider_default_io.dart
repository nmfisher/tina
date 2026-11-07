import 'package:tina_io/tina_io.dart';
import 'package:tina_llm/tina_llm.dart';

/// The native endpoint default (see `provider_default.dart`).
HttpEndpoint nativeHttpEndpoint(String base) => IoHttpEndpoint(endpoint: base);
