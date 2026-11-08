/// `Platform.environment` and the working directory behind
/// [EnvironmentPort]: the only environment surface the engine needs
/// (provider tokens, cache locations).
library;

import 'dart:io';

import 'package:tina_core/tina_core.dart';

final class IoEnvironmentPort implements EnvironmentPort {
  const IoEnvironmentPort();

  @override
  String? env(String name) => Platform.environment[name];

  @override
  String get currentDirectory => Directory.current.path;
}
