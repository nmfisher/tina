/// The HTTP seam. The port itself lives in `tina_core` (`HttpClientPort`)
/// so the engine has zero `dart:io`; the native implementation
/// (`IoHttpEndpoint`) lives in `tina_io` and is injected by the composition
/// root. Tests inject a fake that replays recorded bytes — no network, no
/// credentials, no new dependencies.
library;

import 'package:tina_core/tina_core.dart' as core;

export 'package:tina_core/tina_core.dart'
    show HttpClientPort, HttpClientResponse;

/// The wire-level name for [core.HttpClientPort], kept so provider call
/// sites and test fakes read the same as before the port existed.
typedef HttpEndpoint = core.HttpClientPort;

/// The wire-level name for [core.HttpClientResponse].
typedef HttpResponse = core.HttpClientResponse;
