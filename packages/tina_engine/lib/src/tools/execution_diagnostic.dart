/// Output-derived hints are not proof of failure or authority to grant access.
enum ExecutionDiagnosticKind {
  network,
  dependency,
  nestedFailure,
  sandboxSetup
}

class ExecutionDiagnostic {
  final ExecutionDiagnosticKind kind;
  final String message;
  const ExecutionDiagnostic(this.kind, this.message);
}

List<ExecutionDiagnostic> diagnoseExecution(
    {required String output, required int exitCode, required bool shell}) {
  if (exitCode == 0) {
    return [
      if (shell &&
          RegExp(r'\bexit\s*[:=]\s*[1-9][0-9]*\b', caseSensitive: false)
              .hasMatch(output))
        const ExecutionDiagnostic(
            ExecutionDiagnosticKind.nestedFailure,
            'The shell exited 0, but output mentions a nonzero exit. A nested '
            'operation may have failed, or this may be old log text. Inspect the '
            'actual result; use exec to capture the program exit code directly. '
            'This diagnostic does not authorize a retry or additional access.'),
    ];
  }
  return [
    if (RegExp(
            r'could not resolve|name or service not known|temporary failure in name resolution|got socket error|network is unreachable',
            caseSensitive: false)
        .hasMatch(output))
      const ExecutionDiagnostic(
          ExecutionDiagnosticKind.network,
          'Network/DNS diagnostic: inspect execution_info and connectivity. '
          'Do not change HOME, relocate caches, or request write access based '
          'only on this error.'),
    if (RegExp(r'version solving failed|could not find package .* in cache',
            caseSensitive: false)
        .hasMatch(output))
      const ExecutionDiagnostic(
          ExecutionDiagnosticKind.dependency,
          'Dependency resolution diagnostic: inspect the manifests and effective '
          'cache path. An offline cache miss does not prove the package is absent '
          'from other caches and is not evidence of a write denial.'),
    if (RegExp(r'bwrap:|sandbox-exec:').hasMatch(output))
      const ExecutionDiagnostic(
          ExecutionDiagnosticKind.sandboxSetup,
          'Sandbox setup diagnostic: inspect the backend configuration before '
          'retrying. Do not disable confinement or broaden directory grants to '
          'work around a sandbox setup failure.'),
  ];
}
