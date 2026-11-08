/// The platform [AppIo]: the native one when `dart:io` exists; an
/// unsupported stub when it does not (a wasm build without an injected
/// implementation must fail loudly, not silently misbehave).
library;

import 'app_io.dart';
import 'app_io_unsupported.dart' if (dart.library.io) 'app_io_native.dart';

AppIo platformAppIo() => nativeAppIo();
