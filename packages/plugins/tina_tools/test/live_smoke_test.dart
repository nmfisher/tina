// A live smoke test: one real turn against the real endpoint with the
// real tools. Tagged `live`, skipped by default (see dart_test.yaml) —
//
//     dart test --tags live --run-skipped
//
// It reads TINA_LLM_TOKEN / ANTHROPIC_API_KEY from the environment (the
// provider refuses to open a socket without one) and asks the model to
// write a file with the write tool, then checks the workspace. No
// terminal, no daemon: the host assembles, one turn runs, the file is
// there, the transcript closes.
//
// Run: dart test --tags live --run-skipped
@Tags(['live'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_llm/tina_llm.dart';

void main() {
  late Directory ws;
  late Directory tina;

  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_live_ws_');
    tina = await Directory.systemTemp.createTemp('tina_live_tina_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
    tina.deleteSync(recursive: true);
  });

  test('one live turn: the model writes a file through the sandbox', () async {
    // The model label: TINA_LLM_MODEL when set, the environment's
    // ANTHROPIC_MODEL next (the gateway the token belongs to decides the
    // name), else the provider default the factory used to carry.
    final model = Platform.environment['TINA_LLM_MODEL'] ??
        Platform.environment['ANTHROPIC_MODEL'] ??
        'glm-5.3-flash';
    final host = Host.start(HostConfig(
      providerFactory: (m) => AnthropicProvider(model: m),
      model: model,
      workingDirectory: ws.path,
      plugins: [
        ToolsPlugin(
          workspaceRoot: ws.path,
          tinaDir: tina,
          mode: PermissionMode.normal,
        ),
      ],
    ));

    final outcome = await host
        .send(
          'Create a file named live-smoke.txt containing exactly the text '
          '"live smoke ok". Use the write tool. Do not do anything else.',
          turnId: 'live-smoke',
        )
        .timeout(const Duration(minutes: 3));

    // The turn finished — the assertion is on the workspace, not the
    // prose: the model may phrase anything, the file must be real.
    expect(outcome.stopReason, StopReason.complete,
        reason: 'turn detail: ${outcome.detail}');
    final file = File('${ws.path}/live-smoke.txt');
    expect(file.existsSync(), isTrue,
        reason: 'the model was asked to write live-smoke.txt; got: '
            '${host.session.lastReply}');
    expect(file.readAsStringSync(), contains('live smoke ok'));
    expect(host.session.turns, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
