// Phase B end to end: the TUI over a spawned engine process (Option 1).
// The real `runTui` renderer runs against `RemoteTuiSession` + the
// launcher's `EngineProcess`, with a scripted dual-wire provider behind
// both engines: the wasm engine (`tina-wasm-host`, Anthropic wire over
// WASI HTTP) and the native engine (`dart run bin/tina.dart --pipes`,
// OpenAI-compatible wire) as the parity reference.
//
// One scenario per leg: a streamed plain turn, an ask-mode write that the
// approval dialog allows, a mid-stream cancel, `/plugins` status +
// reload (wasm: the plugin admin command; the native engine has no wasm
// plugin admin), and a clean quit that stops the engine.
//
// Run: dart test test/remote_tui_session_test.dart
@Timeout(Duration(minutes: 15))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina/tui.dart';

import 'package:tina_approvals/tina_approvals.dart' show ApprovalKind;

import 'app_test.dart' show FakeIo, fakeScreen;
import 'package:tina/src/engine_launcher.dart'
    show EngineProcess, wasmEngineArgv;
import 'package:tina/src/tui_remote.dart' show RemoteTuiSession;

/// Polls [condition]; engine turns cross a real process boundary.
Future<void> _waitFor(bool Function() condition, String what,
    {Duration limit = const Duration(seconds: 45)}) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

final class _ScriptedServer {
  HttpServer? _server;
  int get port => _server!.port;
  String get endpoint => 'http://127.0.0.1:$port';

  /// Where the scripted write lands — set per leg before its first turn.
  String workspace = '';

  /// The path the scripted tool call names: absolute for the native
  /// engine, guest-relative for the wasm engine (it sees only preopens).
  String toolFilePath = '';

  Future<void> close() => _server!.close(force: true);

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      try {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final anthropic = request.uri.path.endsWith('/messages');
        await _serve(request, body, anthropic);
      } catch (_) {
        // A cancelled turn tears the socket down mid-write; that is the
        // scenario working, not a failure.
      }
    });
  }

  Future<void> _serve(HttpRequest request, Map body, bool anthropic) async {
    final messages = (body['messages'] as List)
        .whereType<Map>()
        .toList(growable: false);
    final hasToolResult = messages.any((message) => anthropic
        ? (message['content'] as List?)?.any(
                (block) => block is Map && block['type'] == 'tool_result') ==
            true
        : message['role'] == 'tool');
    final lastUser = [
      for (final message in messages)
        if (message['role'] == 'user')
          switch (message['content']) {
            final String text => text,
            final List blocks => [
                for (final block in blocks)
                  if (block is Map && block['type'] == 'text')
                    block['text'] as String,
              ].join(' '),
            _ => '',
          },
    ].last.toLowerCase();

    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    void frame(Object data) {
      request.response.write('data: ${jsonEncode(data)}\n\n');
    }

    Future<void> done() async {
      if (!anthropic) request.response.write('data: [DONE]\n\n');
      await request.response.flush();
      await request.response.close();
    }

    if (hasToolResult) {
      await _text(request, anthropic, frame, ['The note is saved.'], done,
          stepMs: 120);
      return;
    }
    if (lastUser.contains('note')) {
      final input = jsonEncode({
        'filePath': toolFilePath,
        'content': 'remote note\n',
      });
      if (anthropic) {
        frame({
          'type': 'message_start',
          'message': {'id': 'msg-tool', 'usage': {'input_tokens': 21}},
        });
        frame({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_note',
            'name': 'write',
            'input': {},
          },
        });
        frame({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': input},
        });
        frame({'type': 'content_block_stop', 'index': 0});
        frame({
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {'input_tokens': 21, 'output_tokens': 18},
        });
        frame({'type': 'message_stop'});
      } else {
        frame({
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'toolu_note',
                    'type': 'function',
                    'function': {'name': 'write', 'arguments': input},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        });
      }
      await done();
      return;
    }
    if (lastUser.contains('slow')) {
      await _text(request, anthropic, frame,
          List.generate(8, (i) => 'slow chunk $i '), done, stepMs: 250);
      return;
    }
    await _text(request, anthropic, frame, ['ack: ping.'], done, stepMs: 60);
  }

  /// Streams [chunks] as SSE frames with a pause between them — enough
  /// wire time for a cancel to land mid-stream.
  Future<void> _text(
      HttpRequest request,
      bool anthropic,
      void Function(Object) frame,
      List<String> chunks,
      Future<void> Function() done,
      {required int stepMs}) async {
    if (anthropic) {
      frame({
        'type': 'message_start',
        'message': {'id': 'msg-text', 'usage': {'input_tokens': 12}},
      });
      frame({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text'},
      });
    }
    for (final chunk in chunks) {
      frame(anthropic
          ? {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': chunk},
            }
          : {
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': chunk},
                },
              ],
            });
      await request.response.flush();
      await Future<void>.delayed(Duration(milliseconds: stepMs));
    }
    if (anthropic) {
      frame({'type': 'content_block_stop', 'index': 0});
      frame({
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {'input_tokens': 12, 'output_tokens': 40},
      });
      frame({'type': 'message_stop'});
    } else {
      frame({
        'choices': [
          {
            'index': 0,
            'delta': {},
            'finish_reason': 'stop',
          },
        ],
      });
    }
    await done();
  }
}

/// Fixture first: the legs build argv eagerly at registration time.
final server = _ScriptedServer();
final root = Directory.systemTemp.createTempSync('tina_remote_tui_');
final configDir = Directory('${root.path}/config')..createSync();
final configFile = File('${configDir.path}/config');
final workspace = Directory('${root.path}/workspace')
  ..createSync()
  ..createTempSync('.tina');
final wasmWorkspace = Directory('${root.path}/workspace-wasm')
  ..createSync()
  ..createTempSync('.tina');

Future<void> main() async {
  await server.start();
  server.workspace = workspace.path;
  configFile.writeAsStringSync('''
version = 1

[default]
provider = "local"
model = "stub"

[providers.local]
base_url = "${server.endpoint}/v1"
api_key = "fixture"
models = ["stub"]

[plugins]
enabled = [
  "tina/chat-tui",
  "tina/tools",
  "tina/mode",
  "tina/session-controls",
  "tina/persistence",
]
''');

  tearDownAll(() async {
    await server.close();
    root.deleteSync(recursive: true);
  });

  Future<void> driveLeg(String name, List<String> Function() argv,
      {String? workingDirectory,
      Map<String, String> environment = const {},
      required Directory workspace,
      required String toolFilePath,
      bool pluginsReload = false}) async {
    test('$name: turn, streaming, approval, cancel, quit through the TUI',
        () async {
      server.toolFilePath = toolFilePath;
      final handleEvents = <Map<String, dynamic>>[];
      final engine = await EngineProcess.start(
        argv(),
        workingDirectory: workingDirectory,
        environment: environment,
        onEvent: handleEvents.add,
      );
      final session = await RemoteTuiSession.start(engine);
      addTearDown(() async {
        await session.shutdown();
      });

      late LineEditor editor;
      final io = FakeIo();
      final app = runTui(
        session,
        screen: fakeScreen(io),
        editorFor: (screen) =>
            editor = LineEditor(screen: screen, escapeTimeout: Duration.zero),
      );
      void type(String line) => io.feedBytes(utf8.encode('$line\n'));
      bool sawSnapshotWith(bool Function(Map<String, dynamic>) test) =>
          handleEvents.any((event) =>
              event['type'] == 'snapshot' &&
              test((event['features'] as Map?)?.cast<String, Object?>() ??
                  const {}));
      int receipts(String state) => handleEvents
          .where((event) => event['type'] == 'receipt' &&
              event['state'] == state)
          .length;

      await _waitFor(() => editor.isEditing, '$name: editor ready');
      editor.commandProvider = session.createView().commandCompletion;
      editor.completionProvider = session.createView().fileCompletion;

      // 1. A plain turn streams: the chat preview carries tokens while the
      //    work runs, then the turn completes with the reply committed.
      type('ping');
      await _waitFor(
        () => receipts('completed') >= 1,
        '$name: plain turn completes',
      );
      final streamed = sawSnapshotWith((features) =>
          (features['tina/chat-tui'] as Map?)?['preview'] != null &&
          ((features['tina/chat-tui'] as Map)['preview'] as List)
              .isNotEmpty);
      expect(streamed, isTrue, reason: '$name: streaming preview crossed');
      expect(
        handleEvents.any((event) =>
            event['type'] == 'entry' &&
            jsonEncode(event).contains('ack: ping')),
        isTrue,
        reason: '$name: committed reply entry crossed',
      );
      expect(session.canCancel, isFalse, reason: 'idle session has no work');

      // 2. An ask-mode write asks; the dialog's `y` answers over the wire;
      //    the tool runs and the turn completes.
      type('write the outside note');
      await _waitFor(() => session.approvals.pending.isNotEmpty,
          '$name: approval ask surfaces');
      final ask = session.approvals.pending.single;
      expect(ask.kind, ApprovalKind.permission);
      io.feedBytes(utf8.encode('y'));
      await _waitFor(
        () => receipts('completed') >= 2 &&
            handleEvents.any((event) =>
                event['type'] == 'approval-result' &&
                event['accepted'] == true),
        '$name: approved turn completes',
      );
      expect(
        File('${workspace.path}/outside-note.txt').existsSync(),
        isTrue,
        reason: '$name: approved write landed; listing '
            '${Directory(workspace.path).listSync().map((entry) => entry.path).toList()}'
            ' — tool entries: '
            '${[
          for (final event in handleEvents)
            if (event['type'] == 'entry' &&
                jsonEncode(event).contains('tool_result'))
              jsonEncode(event),
        ]}',
      );
      expect(session.approvals.pending, isEmpty);

      // 3. A slow stream cancels from the keyboard: escape cancels the
      //    work, the receipt reports it, and the session idles.
      final runningBefore = receipts('running');
      type('slow');
      await _waitFor(
        () => receipts('running') > runningBefore,
        '$name: slow turn running',
      );
      await _waitFor(() => session.canCancel, '$name: work cancellable');
      editor.inject(EscapeKey());
      await _waitFor(() => session.canCancel == false,
          '$name: cancel settles to idle');
      expect(receipts('cancelled'), greaterThanOrEqualTo(1),
          reason: '$name: the slow turn was cancelled, not completed — '
              'tail: ${[
                for (final event in handleEvents.skip(handleEvents.length > 14
                    ? handleEvents.length - 14
                    : 0))
                  jsonEncode(event).substring(0,
                      jsonEncode(event).length.clamp(0, 220)),
              ]}');
      expect(
        handleEvents.any((event) =>
            event['type'] == 'cancel' && event['accepted'] == true),
        isTrue,
        reason: '$name: the engine accepted the cancel',
      );

      // 4. The plugin admin command (wasm engine only): status renders the
      //    lease book; reload reattaches the artifact through a notice.
      if (pluginsReload) {
        type('/plugins');
        await _waitFor(
          () => handleEvents.any((event) =>
              event['type'] == 'notice' &&
              '${event['text']}'.contains('tina/wasm-prompt')),
          '$name: /plugins status notice',
        );
        type('/plugins reload');
        await _waitFor(
          () => handleEvents.any((event) =>
              event['type'] == 'notice' &&
              '${event['text']}'.contains('reloaded')),
          '$name: /plugins reload notice',
        );
      }

      // 5. Quit: two Ctrl-C stop the renderer; shutdown asks the engine to
      //    exit and it does — code 0.
      editor.inject(ControlKey(ControlCode.ctrlC));
      editor.inject(ControlKey(ControlCode.ctrlC));
      await app.timeout(const Duration(seconds: 30));
      await session.shutdown();
      final exit = await engine.exitCode.timeout(const Duration(seconds: 30),
          onTimeout: () => -1);
      expect(exit, 0,
          reason: '$name: engine exits cleanly; stderr: '
              '${engine.stderrTail.substring(0, engine.stderrTail.length.clamp(0, 900))}');
    });
  }

  // The native engine: the same front-end path over `tina --pipes`.
  var cliRoot = Directory.current;
  while (!File('${cliRoot.path}/bin/tina.dart').existsSync()) {
    if (cliRoot.parent.path == cliRoot.path) {
      throw StateError('cannot locate the CLI application');
    }
    cliRoot = cliRoot.parent;
  }
  driveLeg(
    'native engine over pipes',
    () => [
      Platform.resolvedExecutable,
      'run',
      'bin/tina.dart',
      '--pipes',
      '--config',
      configFile.path,
      '--cwd',
      workspace.path,
      '--no-sandbox',
    ],
    workingDirectory: cliRoot.path,
    workspace: workspace,
    toolFilePath: '${workspace.path}/outside-note.txt',
  );

  // The wasm engine: the packaged host with the embedded component, the
  // plugin artifact attached so /plugins exists. Skipped where the
  // packaging artifacts are absent.
  final host = Platform.environment['TINA_WASM_HOST'] ??
      '/tmp/sigprobe/target/release/tina-wasm-host';
  final pluginArtifact = Platform.environment['TINA_TEST_PLUGIN'] ??
      '/tmp/codex85-loader-integration-20261108/wasm.dart/pkg/tina_wasm_host/testdata/plugin_probe/tina_prompt_plugin.component.wasm';
  if (File(host).existsSync() && File(pluginArtifact).existsSync()) {
    driveLeg(
      'wasm engine over pipes',
      () => wasmEngineArgv(
        hostPath: host,
        workingDirectory: wasmWorkspace.path,
        configPath: configFile.path,
        storePath: '${wasmWorkspace.path}/.tina/sessions.db',
        yolo: false,
        environment: {
          'TINA_LLM_ENDPOINT': '${server.endpoint}/v1',
          'ANTHROPIC_API_KEY': 'fixture',
        },
        extraArgs: [
          '--plugin-component=$pluginArtifact',
          '--plugin-grant=session.read-context',
          '--plugin-watch',
        ],
      ),
      workspace: wasmWorkspace,
      toolFilePath: 'outside-note.txt',
      pluginsReload: true,
    );
  } else {
    test('wasm engine over pipes',
        skip: 'packaged tina-wasm-host or plugin artifact not present',
        () {});
  }
}
