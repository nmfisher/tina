import 'dart:io';

/// The host environment the app runs in — environment variables plus the OS —
/// behind an interface so tests can supply a [FakeEnvironment] instead of
/// mutating the real process environment or depending on [Platform]. Production
/// uses [PlatformEnvironment].
abstract class Environment {
  /// The process environment variables.
  Map<String, String> get env;

  bool get isMacOS;
  bool get isWindows;
  bool get isLinux;

  /// `Platform.operatingSystem` (`macos`, `linux`, `windows`, …).
  String get operatingSystem;
}

/// [Environment] backed by [Platform]. Reads live, so it reflects any env or
/// platform state at access time.
class PlatformEnvironment implements Environment {
  const PlatformEnvironment();

  @override
  Map<String, String> get env => Platform.environment;

  @override
  bool get isMacOS => Platform.isMacOS;

  @override
  bool get isWindows => Platform.isWindows;

  @override
  bool get isLinux => Platform.isLinux;

  @override
  String get operatingSystem => Platform.operatingSystem;
}
