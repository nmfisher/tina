import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_self_update/tina_self_update.dart';

class TerminalStub implements Terminal {
  @override
  void writeln([String? line]) {}
  @override
  Future<String> ask(String prompt) async =>
      throw StateError('unexpected input');
}

class Deny implements ApprovalRequester {
  @override
  Future<ApprovalDecision> request(
          {required String operation,
          required String target,
          required String reason,
          ApprovalKind kind = ApprovalKind.permission, Map<String, Object?> details = const {}}) async =>
      ApprovalDecision.deny;
}

http.Response release(String tag) => http.Response(
    jsonEncode({
      'tag_name': tag,
      'html_url': 'https://example.com/$tag',
      'assets': []
    }),
    200);

void main() {
  late Directory home;
  setUp(
      () => home = Directory.systemTemp.createTempSync('tina-update-status-'));
  tearDown(() => home.deleteSync(recursive: true));
  UpdatePlugin plugin(http.Client client, {bool enabled = true}) {
    final p = UpdatePlugin(
        currentVersion: '0.9.0',
        terminal: TerminalStub(),
        approvals: Deny(),
        backgroundEnabled: enabled,
        checker: ReleaseChecker(
            env: {'HOME': home.path}, currentVersion: '0.9.0', client: client));
    addTearDown(p.closeSession);
    return p;
  }

  test(
      'background check is single-flight, persists availability, explicit check refreshes',
      () async {
    final response = Completer<http.Response>();
    var calls = 0;
    final p = plugin(MockClient(
        (_) async => ++calls == 1 ? await response.future : release('v0.9.0')));
    expect(p.commands.single.allowWhileRunning, isTrue);
    final pending = p.checkInBackground();
    expect(p.status.phase, UpdatePhase.checking);
    expect(identical(pending, p.checkInBackground()), true);
    response.complete(release('v0.9.1'));
    await pending;
    expect(p.status.phase, UpdatePhase.available);
    expect(p.status.tag, 'v0.9.1');
    await p.checkInBackground();
    expect(calls, 1);
    await p.commands.single.handler('check');
    expect(p.status.phase, UpdatePhase.current);
    expect(calls, 2);
  });
  test(
      'failures stay visible, next launch defers, explicit check bypasses backoff',
      () async {
    final failed = plugin(MockClient((_) async => http.Response('', 429)));
    await failed.checkInBackground();
    expect(failed.status.phase, UpdatePhase.failed);
    expect(failed.status.reason, contains('429'));
    var calls = 0;
    final next = plugin(MockClient((_) async {
      calls++;
      return release('v0.9.1');
    }));
    await next.checkInBackground();
    expect(next.status.phase, UpdatePhase.deferred);
    expect(next.status.until, isNotNull);
    expect(calls, 0);
    await next.commands.single.handler('check');
    expect(next.status.phase, UpdatePhase.available);
    expect(calls, 1);
  });
  test('opt-out disables only background traffic', () async {
    var calls = 0;
    final p = plugin(MockClient((_) async {
      calls++;
      return release('v0.9.1');
    }), enabled: false);
    await p.checkInBackground();
    expect(calls, 0);
    await p.commands.single.handler('');
    expect(calls, 1);
  });
  test('late background completion after unload never emits status', () async {
    final response = Completer<http.Response>();
    final p = plugin(MockClient((_) => response.future));
    final pending = p.checkInBackground();
    await Future<void>.delayed(Duration.zero);
    p.closeSession();
    response.complete(release('v0.9.1'));
    await pending;
    expect(p.status.phase, UpdatePhase.checking);
  });
}
