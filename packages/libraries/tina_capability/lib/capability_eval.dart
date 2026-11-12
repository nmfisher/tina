/// The reference evaluators the native enforcement and the parity
/// harness share: the exact decision semantics the wasm.dart host
/// implements over the same document (`policy.rs`), spelled in Dart so
/// both enforcement sites are tested against one parity table.
library;

import 'capability_document.dart';

/// One command verdict with the reason the contract carries.
final class CommandDecision {
  const CommandDecision(this.verdict, this.reason);

  final CommandVerdict verdict;
  final String reason;
}

/// Evaluates the document's command rules against a joined command line:
/// first anchored match decides, no match uses the document's default
/// verdict, reasons carry the matched rule (the same strings the host
/// produces).
CommandDecision evaluateCommand(CapabilityDocument document, String line) {
  for (var i = 0; i < document.rules.length; i++) {
    final rule = document.rules[i];
    final anchored = RegExp('^(?:${rule.pattern})\$');
    if (!anchored.hasMatch(line)) continue;
    return switch (rule.verdict) {
      CommandVerdict.allow => CommandDecision(
          CommandVerdict.allow,
          'rule $i (${rule.pattern}) allows the command',
        ),
      CommandVerdict.deny => CommandDecision(
          CommandVerdict.deny,
          'rule $i (${rule.pattern}) denies the command',
        ),
      CommandVerdict.ask => CommandDecision(
          CommandVerdict.ask,
          'rule $i (${rule.pattern}) requires approval',
        ),
    };
  }
  return switch (document.defaultVerdict) {
    CommandVerdict.allow =>
      const CommandDecision(CommandVerdict.allow, 'default allow'),
    CommandVerdict.deny => const CommandDecision(
        CommandVerdict.deny,
        'the capability policy denies unmatched commands',
      ),
    CommandVerdict.ask => const CommandDecision(
        CommandVerdict.ask,
        'no rule matched the command',
      ),
  };
}

/// Whether an outgoing request to `scheme://host:port` is allowed by the
/// document's network entries: `allow_all` in yolo, otherwise exact
/// host(+scheme-defaulted port) or `*.suffix` on label boundaries.
bool domainAllowed(
  CapabilityDocument document,
  String scheme,
  String host,
  int port,
) {
  if (document.allowAllDomains) return true;
  final defaultPort = switch (scheme) {
    'https' => 443,
    'http' => 80,
    _ => -1,
  };
  final lowerHost = host.toLowerCase();
  for (final entry in document.domains) {
    var pattern = entry.domain;
    int? entryPort;
    final split = pattern.lastIndexOf(':');
    if (split > 0) {
      final parsed = int.tryParse(pattern.substring(split + 1));
      if (parsed != null) {
        entryPort = parsed;
        pattern = pattern.substring(0, split);
      }
    }
    final portOk = entryPort != null ? entryPort == port : port == defaultPort;
    if (!portOk) continue;
    final wildcard = pattern.startsWith('*.');
    final hostOk = wildcard
        ? lowerHost.endsWith(pattern.substring(1))
        : lowerHost == pattern;
    if (hostOk) return true;
  }
  return false;
}
