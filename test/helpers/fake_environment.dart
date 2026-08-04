import 'package:tina/platform/environment.dart';

/// An [Environment] with overrideable fields, for tests that need to control env
/// vars or the OS without touching the real process.
class FakeEnvironment implements Environment {
  @override
  final Map<String, String> env;
  @override
  final bool isMacOS;
  @override
  final bool isWindows;
  @override
  final bool isLinux;
  @override
  final String operatingSystem;

  FakeEnvironment({
    Map<String, String>? env,
    this.isMacOS = false,
    this.isWindows = false,
    this.isLinux = true,
    this.operatingSystem = 'linux',
  }) : env = env ?? const {};
}
