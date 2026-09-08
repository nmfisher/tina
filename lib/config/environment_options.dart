/// Whether the first-load environment agent (ENVIRONMENT.md population) may
/// run in the background without asking. From `[environment] auto_populate`
/// in ~/.tina/config; `ask` is the default so a token-spending agent turn
/// never starts silently.
enum EnvironmentAutoPopulate { ask, always, never }

/// Parse the raw `[environment] auto_populate` value. Unknown / absent →
/// [EnvironmentAutoPopulate.ask] (the safe default).
EnvironmentAutoPopulate parseEnvironmentAutoPopulate(String? raw) =>
    switch (raw) {
      'always' => EnvironmentAutoPopulate.always,
      'never' => EnvironmentAutoPopulate.never,
      _ => EnvironmentAutoPopulate.ask,
    };
