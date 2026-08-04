import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('HeadlessHost', () {
    test('is a HostInterface and an AgentSink seam for Agent', () {
      final host = HeadlessHost();
      expect(host, isA<HostInterface>());
      // Agent takes `sink: AgentSink`; HeadlessHost must satisfy that. Using it
      // as a tear-off asker mirrors bin/tina.dart's wiring.
      expect(host.askPermission, isA<PermissionAsker>());
    });

    test('text() writes the delta to stdout and emits it on the bus', () async {
      final out = StringBuffer();
      final host = HeadlessHost(write: out.write);

      final events = <AgentEvent>[];
      final sub = host.eventBus.events.listen(events.add);

      host.text('hello ');
      host.text('world');
      host.newline();

      // The bus is an async broadcast controller; let its microtasks drain
      // before asserting on the collected events.
      await Future.delayed(Duration.zero);

      expect(out.toString(), 'hello world\n');
      await sub.cancel();
      expect(
          events.whereType<TextAgentEvent>().map((e) => e.text).toList(),
          ['hello ', 'world']);
      // newline() forwards but emits nothing.
      expect(events.whereType<TextAgentEvent>().length, 2);
    });

    test('tool lifecycle renders a readable line per call', () {
      final out = StringBuffer();
      final host = HeadlessHost(write: out.write);

      host.toolStart(
          const ToolStartEvent('bash', 't1', {'command': 'git status'}));
      host.toolComplete(
          const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

      expect(out.toString(), '→ bash: git status\n  ok\n');
    });

    test('a failed tool reports the truncated result', () {
      final out = StringBuffer();
      final host = HeadlessHost(write: out.write);

      // Non-const: 'boom' * 100 (string repeat) isn't a const operation.
      host.toolComplete(ToolCompleteEvent('bash', 't1',
          isError: true, result: 'boom' * 100));

      final s = out.toString();
      expect(s, startsWith('  failed: '));
      expect(s, endsWith('…\n'));
      // '  failed: ' (10) + 200-char cap + '…' (1) + '\n' (1) = 212.
      expect(s.length, 212);
    });

    test('tool stderr output routes to the error sink, stdout to out', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final host = HeadlessHost(write: out.write, writeErr: err.write);

      host.toolOutput(const ToolOutputEvent('bash', 't1', 'progress'));
      host.toolOutput(
          const ToolOutputEvent('bash', 't1', 'oops', stderr: true));

      expect(out.toString(), 'progress');
      expect(err.toString(), 'oops');
    });

    test('error/warning notices route to stderr; info to stdout', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final host = HeadlessHost(write: out.write, writeErr: err.write);

      host.notice('all good', kind: NoticeKind.info);
      host.notice('boom', kind: NoticeKind.error);

      expect(out.toString(), 'all good');
      expect(err.toString(), 'boom');
    });

    test('askPermission refuses with a flag hint and returns denyOnce',
        () async {
      final err = StringBuffer();
      final host = HeadlessHost(writeErr: err.write);

      final res = await host.askPermission(
          const PermissionPrompt('bash', {'command': 'rm -rf /'}));

      expect(res, PermissionResponse.denyOnce);
      expect(err.toString(),
          contains('use --allow "bash:rm *" or --yolo'));
      expect(err.toString(), contains('bash:'));
    });

    test('showMessage routes by style', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final host = HeadlessHost(write: out.write, writeErr: err.write);

      host.showMessage('hi', style: HostMessageStyle.normal);
      host.showMessage('warn', style: HostMessageStyle.warning);
      host.showMessage('err', style: HostMessageStyle.error);

      expect(out.toString(), 'hi');
      expect(err.toString(), 'warnerr');
    });

    test('dispose closes the bus so later emits are dropped', () async {
      final host = HeadlessHost();
      final events = <AgentEvent>[];
      final sub = host.eventBus.events.listen(events.add);

      host.text('before');
      await host.dispose();
      host.text('after');

      await sub.cancel();
      final texts = events.whereType<TextAgentEvent>().map((e) => e.text);
      expect(texts, ['before']);
    });
  });
}
