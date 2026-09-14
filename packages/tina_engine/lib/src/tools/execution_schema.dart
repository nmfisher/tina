/// Shared, stable input fields for direct and shell execution.
const Map<String, dynamic> executionProperties = {
  'environment': {
    'type': 'object',
    'additionalProperties': {'type': 'string'},
    'description':
        'Explicit environment overrides. Values are literal; preserve HOME and cache settings unless intentionally changing them. Use absolute cache paths.',
  },
  'cwd': {
    'type': 'string',
    'description': 'Working directory for the command. Absolute or relative '
        'to the agent cwd. Defaults to the agent cwd.',
  },
  'writablePaths': {
    'type': 'array',
    'items': {'type': 'string'},
    'description': 'Existing absolute directories needing write access '
        'outside the sandbox, e.g. a toolchain cache. Requires explicit '
        'user approval even when the command is already allowed. '
        'Request only the narrow directories needed.',
  },
  'retrySafety': {
    'type': 'string',
    'description': 'For a retry after an identified sandbox write failure, '
        'summarize checks for partial effects and why replaying the '
        'command is safe. Inspect the failed result before supplying this. '
        'Tina will request directory approval before the retry runs.',
  },
  'accessReason': {
    'type': 'string',
    'description': 'Why this command needs the requested writablePaths. '
        'Required when writablePaths is nonempty.',
  },
  'timeoutSeconds': {
    'type': 'integer',
    'description': 'Override the default 60s timeout. Clamped to 1–900s.',
  },
};
