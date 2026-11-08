/// The I/O ports: the engine's only surface to the world outside the
/// dart:core libraries. Wasm (standalone) has no `dart:io` — no files,
/// no sockets, no processes, no environment — so engine packages depend
/// on these contracts and the composition root injects implementations:
/// native ones from `tina_io`, host-supplied ones in a wasm build.
///
/// Deliberately minimal: one method per real engine call site found by the
/// stage-2 audit (docs/wasm_stage2_audit.md). Exceptions, not booleans:
/// callers mirror `dart:io` throwing semantics and catch, so both the
/// native and the wasm implementation behave identically.
library;

import 'dart:math' as math;

/// One HTTP response the way the callers need it: status, headers, and the
/// body as a stream of chunks. A streaming SSE response arrives as many
/// chunks over time; a recorded one replays them from a list.
final class HttpClientResponse {
  const HttpClientResponse({
    required this.statusCode,
    this.headers = const {},
    Stream<List<int>>? body,
  }) : _body = body;

  final int statusCode;
  final Map<String, String> headers;

  final Stream<List<int>>? _body;

  /// The body bytes, as they arrive.
  Stream<List<int>> get body => _body ?? const Stream<List<int>>.empty();
}

/// POST/GET against an endpoint. The base URL is constructor state of the
/// implementation; [path] hangs off it. The methods are the two the engine
/// actually issues: providers POST message calls, the model catalogue GETs.
abstract interface class HttpClientPort {
  /// POST [path] with [headers] and [body], and hand back the response.
  Future<HttpClientResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  });

  /// GET [path] — the catalogue's fetch, and anything else that only reads.
  Future<HttpClientResponse> get(
    String path, {
    Map<String, String> headers = const {},
  });

  /// Release the underlying client. Callers that did not create the
  /// implementation still own it through the port.
  void close();
}

/// The file operations the engine needs: the models.dev catalogue cache.
/// Throws on missing/unwritable paths like `dart:io` does — callers catch.
abstract interface class FileSystemPort {
  /// Read [path] as a UTF-8 string.
  Future<String> readText(String path);

  /// Write [contents] to [path], flushed — a later reader sees it whole.
  Future<void> writeText(String path, String contents);

  /// Create [path], parents included when [recursive].
  Future<void> createDirectory(String path, {bool recursive = false});

  /// The modification time of [path].
  Future<DateTime> lastModified(String path);
}

/// One finished process run: exit status and decoded output.
final class ProcessRunResult {
  const ProcessRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// How one access-profile rule judges a command line. The vocabulary
/// mirrors tina_mode's command-pattern rules; under wasm the HOST is the
/// enforcement point (see wasm.dart's `tina:process` spec).
enum ProcessVerdict { allow, deny, ask }

/// One command-pattern rule: a conservative regular expression the
/// evaluator anchors to the entire command line. First match decides.
final class ProcessRule {
  const ProcessRule(this.pattern, this.verdict);

  final String pattern;
  final ProcessVerdict verdict;
}

/// The policy table that travels with process spawns: the engine holds
/// tina_mode's command rules and sends them per spawn; the side that can
/// spawn (the host, under wasm) evaluates them before spawning.
final class ProcessAccessProfile {
  const ProcessAccessProfile(this.rules);

  final List<ProcessRule> rules;
}

/// An `ask` verdict surfaced to the engine's approval flow: the command
/// line and why policy deferred it.
final class ProcessApprovalRequest {
  const ProcessApprovalRequest({required this.command, required this.reason});

  final String command;
  final String reason;
}

/// The engine's answer to a [ProcessApprovalRequest]: whether the spawn
/// may proceed. In production this is tina_mode's approval flow (policy
/// table, then the human); a probe programs it.
typedef ProcessApprover = Future<bool> Function(ProcessApprovalRequest request);

/// The policy decision for one command line.
final class ProcessPolicyDecision {

  const ProcessPolicyDecision.allow()
    : verdict = ProcessVerdict.allow,
      reason = null;

  const ProcessPolicyDecision.refused(String reason)
    : verdict = ProcessVerdict.deny,
      reason = reason;

  const ProcessPolicyDecision.ask(String reason)
    : verdict = ProcessVerdict.ask,
      reason = reason;

  final ProcessVerdict verdict;

  /// Why, for deny and ask. The exact string the wasm host produces -
  /// these strings are interface contract (see wasm.dart's
  /// `tina:process` spec).
  final String? reason;
}

/// Evaluates [profile] against a command line exactly the way the wasm
/// host does: each pattern is anchored to the entire line, the first
/// match decides, no match asks (toward the human, not silent refusal),
/// and an invalid pattern fails closed. Shared by the native port so
/// both sides of the boundary produce the same verdicts.
ProcessPolicyDecision evaluateProcessPolicy(
  ProcessAccessProfile profile,
  String command,
) {
  for (var i = 0; i < profile.rules.length; i++) {
    final rule = profile.rules[i];
    // An invalid pattern fails closed, mirroring the host.
    final anchored = _anchored(rule.pattern);
    if (anchored == null) {
      return ProcessPolicyDecision.refused(
        'rule $i (${rule.pattern}) is not a valid pattern',
      );
    }
    if (!anchored.hasMatch(command)) continue;
    return switch (rule.verdict) {
      ProcessVerdict.allow => const ProcessPolicyDecision.allow(),
      ProcessVerdict.deny => ProcessPolicyDecision.refused(
        'rule $i (${rule.pattern}) denies the command',
      ),
      ProcessVerdict.ask => ProcessPolicyDecision.ask(
        'rule $i (${rule.pattern}) requires approval',
      ),
    };
  }
  return const ProcessPolicyDecision.ask('no rule matched the command');
}

/// `pattern` anchored to the entire line, or null when it does not
/// compile (the conservative subset tina_mode's rules use always does).
RegExp? _anchored(String pattern) {
  try {
    return RegExp('^(?:$pattern)\$');
  } on FormatException {
    return null;
  }
}

/// A spawn refused by policy: the reason is for the engine to surface
/// (the rule that denied, or the approval flow's refusal).
final class ProcessRefusedException implements Exception {
  const ProcessRefusedException(this.reason);

  final String reason;

  @override
  String toString() => 'ProcessRefusedException: $reason';
}

/// A spawn the host could not carry out (missing binary, bad working
/// directory): mirrors the shape of `dart:io`'s `ProcessException`,
/// which wasm builds cannot construct.
final class ProcessLaunchException implements Exception {
  const ProcessLaunchException(this.message);

  final String message;

  @override
  String toString() => 'ProcessLaunchException: $message';
}

/// Run one program with literal arguments — no shell. No engine call site
/// yet (`tina_tools` and `tina_mcp` own process spawn today and migrate in
/// stage 3+); the contract is here so that migration does not invent a
/// second one.
///
/// A configured access profile (native or wasm implementation) turns
/// spawns into policy decisions: refusals throw [ProcessRefusedException]
/// and `ask` verdicts go through the configured [ProcessApprover] before
/// anything runs.
abstract interface class ProcessPort {
  /// Run [executable] to completion, feeding [stdin] when given.
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  });
}

/// Reading the clock. `DateTime.now()` is dart:core and builds in wasm, but
/// the port makes time explicit and overridable — the loop stamps every log
/// entry through it, and tests can pin it.
abstract interface class ClockPort {
  DateTime now();
}

/// The system clock: dart:core, wasm-safe, native-identical.
final class SystemClock implements ClockPort {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// Random integers for opaque ids (session epochs, question epochs).
/// `Random.secure` is dart:math and builds in wasm; whether the runtime
/// supports a secure source there is a stage-3 verification item, and a wasm
/// host can inject its own implementation regardless.
abstract interface class RandomPort {
  /// A uniform int in `[0, max)`, as unbiased as the implementation allows.
  int nextInt(int max);
}

/// The system random source: cryptographically secure on the VM.
final class SystemRandom implements RandomPort {
  SystemRandom() : _random = math.Random.secure();

  final math.Random _random;

  @override
  int nextInt(int max) => _random.nextInt(max);
}

/// The environment a native process would see: variable lookups and the
/// working directory. Wasm has neither — an implementation must be
/// injected, and the engine fails closed without one.
abstract interface class EnvironmentPort {
  /// The value of [name], or null when unset/unknown.
  String? env(String name);

  /// The current working directory, as a path string.
  String get currentDirectory;
}
