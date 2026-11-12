/// Manifest consent (design doc section 4): the installer shows each
/// capability, the user approves or denies per capability, and the
/// approved set becomes the plugin's recorded grants.
///
/// Rules:
/// - every manifest capability is asked; there is no accept-all;
/// - denial of an optional capability installs-and-degrades;
/// - denial of a required capability refuses the install;
/// - non-interactive installs opt in only via explicit `--grant` flags.
library tina_plugin_registry;

import 'entry.dart';

/// A single consent decision.
class ConsentDecision {
  const ConsentDecision({
    required this.capability,
    required this.granted,
    required this.grantString,
    required this.enforcedByHost,
  });

  final Map<String, Object?> capability;
  final bool granted;
  final String grantString;

  /// Whether the running host accepts this id today (recorded grants the
  /// host does not accept are mounted as recorded-but-unenforced).
  final bool enforcedByHost;
}

/// The outcome of a consent flow.
class ConsentOutcome {
  const ConsentOutcome({
    required this.decisions,
    required this.aborted,
    this.abortReason,
  });

  final List<ConsentDecision> decisions;
  final bool aborted;
  final String? abortReason;

  List<String> grantedStrings() =>
      decisions.where((d) => d.granted).map((d) => d.grantString).toList();

  List<String> deniedIds() =>
      decisions.where((d) => !d.granted).map((d) => d.capability['id'] as String).toList();
}

/// The user-facing question callback. Returns true to grant. The prompt
/// implementation renders [renderCapability] itself; tests substitute.
typedef ConsentPrompt = bool Function(ConsentQuestion question);

class ConsentQuestion {
  const ConsentQuestion({
    required this.capability,
    required this.grantString,
    required this.required,
    required this.defaultAnswer,
  });

  final Map<String, Object?> capability;
  final String grantString;
  final bool required;
  final bool defaultAnswer;
}

/// Interactive consent: ask the [prompt] for every manifest capability.
ConsentOutcome runInteractiveConsent(
    ParsedEntry entry, ConsentPrompt prompt) {
  final decisions = <ConsentDecision>[];
  for (final capability in entry.capabilities) {
    final grantString = canonicalGrantString(capability);
    final id = capability['id'] as String;
    final required = capabilityRequired(capability);
    final question = ConsentQuestion(
      capability: capability,
      grantString: grantString,
      required: required,
      // The default is deny (design: default deny everywhere; the session
      // store's wording makes the worst case explicit).
      defaultAnswer: false,
    );
    final granted = prompt(question);
    decisions.add(
      ConsentDecision(
        capability: capability,
        granted: granted,
        grantString: grantString,
        enforcedByHost: hostAcceptedGrants.contains(id),
      ),
    );
  }
  final deniedRequired = decisions
      .where((d) => !d.granted && capabilityRequired(d.capability))
      .map((d) => d.capability['id'] as String)
      .toList();
  if (deniedRequired.isNotEmpty) {
    return ConsentOutcome(
      decisions: decisions,
      aborted: true,
      abortReason:
          'required capability denied: ${deniedRequired.join(', ')} - '
          'the plugin declares it cannot work without it; not installed',
    );
  }
  return ConsentOutcome(decisions: decisions, aborted: false);
}

/// Non-interactive consent: only explicitly passed `--grant` ids are
/// granted; everything else is denied; a denied required capability aborts.
ConsentOutcome runNonInteractiveConsent(ParsedEntry entry, Set<String> grants) {
  final decisions = <ConsentDecision>[];
  for (final capability in entry.capabilities) {
    final grantString = canonicalGrantString(capability);
    final id = capability['id'] as String;
    final granted = grants.contains(id) || grants.contains(grantString);
    decisions.add(
      ConsentDecision(
        capability: capability,
        granted: granted,
        grantString: grantString,
        enforcedByHost: hostAcceptedGrants.contains(id),
      ),
    );
  }
  final deniedRequired = decisions
      .where((d) => !d.granted && capabilityRequired(d.capability))
      .map((d) => d.capability['id'] as String)
      .toList();
  if (deniedRequired.isNotEmpty) {
    return ConsentOutcome(
      decisions: decisions,
      aborted: true,
      abortReason:
          'required capability not granted non-interactively: '
          '${deniedRequired.join(', ')} - pass --grant <id> or install interactively',
    );
  }
  return ConsentOutcome(decisions: decisions, aborted: false);
}

/// Human-readable consent copy for one capability, following the design's
/// wording rules: name the surface plainly, state the default, and for
/// sensitive tiers say the worst case in one sentence.
String consentCopy(Map<String, Object?> capability) {
  final id = capability['id'] as String;
  final grantString = canonicalGrantString(capability);
  final required = capabilityRequired(capability) ? 'required' : 'optional';
  final summary = capability['summary'] is String
      ? capability['summary'] as String
      : '';
  switch (id) {
    case 'session-store' when capability['access'] == 'read':
      return '$grantString ($required)\n'
          '  Read FULL PAST CONVERSATION HISTORY from this machine\'s '
          'session store, including message text. This is everything you '
          'have said in Tina sessions. Default is denied.\n'
          '  $summary';
    case 'session-store':
      return '$grantString ($required)\n'
          '  Read PAST CONVERSATION HISTORY from this machine\'s session '
          'store - redacted: session ids, model names, message roles and '
          'lengths only. Message text is NOT included. Default is denied.\n'
          '  $summary';
    case 'filesystem':
      final mode = capability['mode'] ?? 'ro';
      final paths = capability['paths'] is List
          ? (capability['paths'] as List).join(', ')
          : 'none';
      return '$grantString ($required)\n'
          '  Read${mode == 'rw' ? ' AND WRITE' : ''} files through the '
          'sandbox, limited to: $paths. Nothing outside these paths is '
          'visible. Default is denied.\n  $summary';
    case 'network':
      final domains = capability['domains'] is List
          ? (capability['domains'] as List).join(', ')
          : 'none';
      return '$grantString ($required)\n'
          '  Make network calls, limited to these hosts: $domains. All '
          'calls are mediated; hosts outside the list are refused. '
          'Default is denied.\n  $summary';
    default:
      return '$grantString ($required)\n  $summary';
  }
}
