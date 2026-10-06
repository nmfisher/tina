import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_tools/tina_tools.dart';

final class DialogChannel implements ApprovalChannel {
  DialogChannel(KeySource Function(ApprovalTicket) keys)
      : asker = QueuedDialogAsker(keysFor: keys);
  final QueuedDialogAsker asker;
  @override
  Future<void> deliver(ApprovalTicket ticket) => asker.ask(ticket);
}

final class GatedKeys implements KeySource {
  final gate = Completer<ApprovalKey?>();
  @override
  Future<ApprovalKey?> next() => gate.future;
}

void main() {
  test('queued dialogs retain request/answer pairing', () async {
    final gate = GatedKeys();
    final shown = <String>[];
    final channel = DialogChannel((ticket) {
      shown.add(ticket.request.target);
      return shown.length == 1
          ? gate
          : ScriptedKeySource([ApprovalKey.confirm]);
    });
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    final first = service.request(
        operation: 'write', target: '/first', reason: 'outside');
    final second = service.request(
        operation: 'write', target: '/second', reason: 'outside');
    await Future<void>.delayed(Duration.zero);
    expect(shown, ['/first']);
    gate.gate.complete(ApprovalKey.cancel);
    expect(await first, ApprovalDecision.deny);
    expect(await second, ApprovalDecision.allow);
    expect(shown, ['/first', '/second']);
  });

  test('shutdown dismisses active and queued dialogs without waiting for keys',
      () async {
    final gate = GatedKeys();
    var shown = 0;
    final channel = DialogChannel((_) {
      shown++;
      return gate;
    });
    final service = ApprovalsPlugin(channel: channel);
    final first = service.request(
        operation: 'write', target: '/first', reason: 'outside');
    final second = service.request(
        operation: 'write', target: '/second', reason: 'outside');
    await Future<void>.delayed(Duration.zero);
    service.closeSession();
    expect(await first, ApprovalDecision.deny);
    expect(await second, ApprovalDecision.deny);
    await Future<void>.delayed(Duration.zero);
    expect(channel.asker.currentDialog, isNull);
    expect(shown, 1);
    gate.gate.complete(ApprovalKey.confirm);
  });

  for (final decision in ApprovalDecision.values) {
    test('sandbox adapter handles $decision and the resolved operation',
        () async {
      final channel = StreamApprovalChannel();
      final requests = <ApprovalRequest>[];
      final subscription = channel.requests.listen((request) {
        requests.add(request);
        channel.respond(request.id, decision);
      });
      final service = ApprovalsPlugin(channel: channel);
      addTearDown(() async {
        service.closeSession();
        channel.closeSession();
        await subscription.cancel();
      });
      final response = requesterApprover(service)(
          (op: FileOp.write, path: '/resolved/path'), 'outside');
      if (decision != ApprovalDecision.allow &&
          decision != ApprovalDecision.allowAlways) {
        await expectLater(response, throwsA(isA<SandboxViolation>()));
      } else {
        expect(
            await response,
            decision == ApprovalDecision.allow
                ? Approval.yes
                : Approval.always);
      }
      expect(requests.single.operation, 'write');
      expect(requests.single.target, '/resolved/path');
      expect(requests.single.reason, 'outside');
      expect(requests.single.details, isNot(contains('read_directory')));
    });
  }

  for (final allow in [true, false]) {
    test(
        'dialog ${allow ? 'allows and remembers' : 'denies'} actual sandbox writes',
        () async {
      final root = Directory.systemTemp.createTempSync('approval-sandbox-');
      final workspace = Directory('${root.path}/workspace')..createSync();
      final target = File('${root.path}/outside');
      addTearDown(() => root.deleteSync(recursive: true));
      var shown = 0;
      final channel = DialogChannel((_) {
        shown++;
        return ScriptedKeySource(
            [if (!allow) ApprovalKey.cancel, ApprovalKey.always]);
      });
      final service = ApprovalsPlugin(channel: channel);
      addTearDown(service.closeSession);
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          workspaceRoot: workspace.path,
          tinaDir: Directory('${workspace.path}/.tina'),
          approver: requesterApprover(service));
      final tool = WriteTool(fs: sandbox, workspaceRoot: workspace.path);
      final result =
          await tool.execute({'filePath': target.path, 'content': 'one'});
      expect(result.isError, !allow, reason: result.content);
      expect(target.existsSync(), allow);
      expect(shown, 1);
      if (allow) {
        expect(
            (await tool.execute({'filePath': target.path, 'content': 'two'}))
                .isError,
            false);
        expect(shown, 1);
        expect(target.readAsStringSync(), 'two');
      }
    });
  }
}
