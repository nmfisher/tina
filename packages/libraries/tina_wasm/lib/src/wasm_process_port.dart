/// The wasm process port: `tina_core`'s [ProcessPort] over the
/// `tina:process` host import (see this package's `wit/deps/tina-process`),
/// the interface the Rust host in wasm.dart implements.
///
/// WASI has no process spawn, so the HOST runs real processes on the
/// engine's behalf - and enforces: every spawn carries the access
/// profile, which the host evaluates before any process exists. The
/// outcomes cross the boundary as data: `denied` surfaces to the engine
/// as [ProcessRefusedException], and `ask` comes back as an approval
/// request this port routes through the configured [ProcessApprover]
/// (tina_mode's decision pipeline, then the human); the answer returns
/// to the host with `respond`, and only an allow spawns.
///
/// Output streams back through the same component-model stream
/// machinery `tina:http` bodies use, so [run] sees chunks as the child
/// writes them; here they are drained and decoded like
/// `dart:io`'s `Process.run` output.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/tina_process.dart' as tina_process;

/// [ProcessPort] over `tina:process`.
final class WasmProcessPort implements ProcessPort {
  WasmProcessPort({
    required tina_process.Process process,
    required ProcessAccessProfile profile,
    required ProcessApprover approver,
  }) : _process = process,
       _profile = profile,
       _approver = approver;

  final tina_process.Process _process;
  final ProcessAccessProfile _profile;
  final ProcessApprover _approver;

  @override
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    final started = await _start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      stdin: stdin,
    );
    // Drain both pipes concurrently: a child blocked on a full stderr
    // pipe while we read stdout would deadlock itself.
    final results = await Future.wait([
      _drain(started.stdout),
      _drain(started.stderr),
    ]);
    final exit = await _exit(started.id);
    return ProcessRunResult(
      exitCode: exit,
      stdout: results[0],
      stderr: results[1],
    );
  }

  /// Spawns through the host, riding the approval round-trip until the
  /// child exists or policy refuses it.
  Future<({int id, Stream<Uint8List> stdout, Stream<Uint8List> stderr})>
  _start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) async {
    var outcome = await _process.spawn(
      req: (
        argv: [executable, ...arguments],
        cwd: workingDirectory == null
            ? cm.Option.none
            : cm.Option<String>.some(workingDirectory),
        env: [
          for (final entry in (environment ?? const {}).entries)
            (entry.key, entry.value),
        ],
        stdin: stdin == null
            ? cm.Option.none
            : cm.Option<List<int>>.some(utf8.encode(stdin)),
        profile: (
          rules: [
            for (final rule in _profile.rules)
              (pattern: rule.pattern, verdict: _verdict(rule.verdict)),
          ],
        ),
      ),
    );

    while (true) {
      final value = _unwrap(outcome);
      switch (value) {
        case tina_process.TypesOutcomeStarted(:final payload):
          return (
            id: payload.id,
            stdout: payload.stdout,
            stderr: payload.stderr,
          );
        case tina_process.TypesOutcomeDenied(:final payload):
          throw ProcessRefusedException(payload);
        case tina_process.TypesOutcomeApproval(:final payload):
          // The `ask` outcome: the approval request has crossed the
          // boundary to the engine; route it through the approval flow
          // and answer the host.
          final allowed = await _approver(
            ProcessApprovalRequest(
              command: payload.command,
              reason: payload.reason,
            ),
          );
          outcome = await _process.respond(
            approval: payload.id,
            allow: allowed,
          );
      }
    }
  }

  Future<String> _drain(Stream<Uint8List> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
    }
    // The native port decodes with `allowMalformed`; matching it keeps
    // the two sides byte-identical for any child output.
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<int> _exit(int id) async {
    final exit = _unwrap(await _process.wait(id: id));
    return switch (exit) {
      tina_process.TypesExitCode(:final payload) => payload,
      // `dart:io` reports a signal-terminated child with the negated
      // signal as its exit code; the engine's callers expect that shape.
      tina_process.TypesExitSignal(:final payload) => -payload,
    };
  }

  tina_process.TypesVerdict _verdict(ProcessVerdict verdict) {
    return switch (verdict) {
      ProcessVerdict.allow => tina_process.TypesVerdict.allow,
      ProcessVerdict.deny => tina_process.TypesVerdict.deny,
      ProcessVerdict.ask => tina_process.TypesVerdict.ask,
    };
  }

  T _unwrap<T>(cm.Result<T, tina_process.TypesError> result) {
    return switch (result) {
      cm.OkResult(:final value) => value,
      cm.ErrorResult(:final value) => throw ProcessLaunchException(
        switch (value) {
          tina_process.TypesErrorMessage(:final payload) => payload,
        },
      ),
    };
  }
}
