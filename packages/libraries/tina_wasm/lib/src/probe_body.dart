/// The exit-test probe: one tina-shaped run through the engine's ports.
///
/// The same body runs natively (injected `tina_io` ports) and under
/// wasmtime (injected `tina_wasm` ports): it reads a config TOML through
/// the filesystem port, writes a file and reads it back, and makes one
/// streaming provider-style call through the HTTP port. Everything it
/// reports is deterministic - chunk texts, token counts, config values -
/// so the recorded output of the two runs must be identical, line for
/// line.
library;

import 'package:toml/toml.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

/// One recorded line: the same events `run_native` and the Rust runner
/// both serialize, so native and wasm output can be compared byte for
/// byte.
abstract interface class ProbeRecorder {
  void string(String value);
  void integer(int value);
  void boolean(bool value);
}

/// Runs the probe. [endpointBase] is the provider gateway base URL (the
/// local fake under test); the provider path hangs off it.
Future<void> runProbe({
  required FileSystemPort files,
  required HttpClientPort Function(String endpoint) endpoint,
  required EnvironmentPort environment,
  required ClockPort clock,
  required RandomPort random,
  required ProbeRecorder recorder,
  String configPath = 'config/probe.toml',
  String outDir = 'out',
}) async {
  recorder.string('probe: config');
  final configText = await files.readText(configPath);
  final config = TomlDocument.parse(configText).toMap();
  recorder.string('config model = ${config['model']}');
  recorder.string('config max_tokens = ${config['generation']['max_tokens']}');
  recorder.string('config endpoint = ${config['endpoint']}');

  recorder.string('probe: files');
  await files.createDirectory(outDir, recursive: true);
  final written = 'probe wrote this at ${config['model']} request';
  await files.writeText('$outDir/probe-write.txt', written);
  final readBack = await files.readText('$outDir/probe-write.txt');
  recorder.string('read back: $readBack');
  recorder.boolean(readBack == written);
  final modified = await files.lastModified('$outDir/probe-write.txt');
  recorder.boolean(modified.isAfter(DateTime(2000)));

  recorder.string('probe: environment');
  final endpointBase = environment.env('TINA_LLM_ENDPOINT');
  recorder.string('endpoint = $endpointBase');

  recorder.string('probe: clock/random');
  recorder.boolean(clock.now().isAfter(DateTime(2020, 1, 1)));
  recorder.boolean(random.nextInt(1) == 0);
  final biased = random.nextInt(97);
  recorder.boolean(biased >= 0 && biased < 97);

  recorder.string('probe: provider stream');
  final provider = AnthropicProvider(
    model: config['model'] as String? ?? 'probe-model',
    endpoint: endpoint(endpointBase ?? 'http://127.0.0.1:8730'),
    environment: environment,
    stallTimeout: const Duration(seconds: 30),
  );
  final answer = StringBuffer();
  var events = 0;
  var deltas = 0;
  MessageComplete? completion;
  await for (final event in provider.send(
    system: 'You are the stage-3 exit probe.',
    messages: const [
      Message(
        role: Role.user,
        content: [TextBlock('Stream me one short greeting.')],
      ),
    ],
    tools: const [],
  )) {
    events++;
    switch (event) {
      case TextDelta(:final text):
        answer.write(text);
        deltas++;
        recorder.string('delta $deltas: $text');
      case MessageComplete():
        completion = event;
      case StreamError(:final error):
        recorder.string('error: $error');
      case StreamEvent():
        break;
    }
  }
  recorder.string('answer: $answer');
  recorder.string('events: $events, deltas: $deltas');
  if (completion != null) {
    recorder.string('stop_reason: ${completion.stopReason}');
    recorder.string(
      'usage: in=${completion.usage?.inputTokens} '
      'out=${completion.usage?.outputTokens}',
    );
  } else {
    recorder.string('no completion');
  }
  provider.close();
}
