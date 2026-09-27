// The Approver wiring: the sandbox's questions are answered through the
// approval dialog's decision half — three answers, one ask at a time, and
// the sandbox keeps its fail-closed behavior and its "always" memory.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_tools/tina_tools.dart';

/// A key source whose next key waits on a gate — for holding a dialog open.
class _GatedKeys implements KeySource {
  final Completer<ApprovalKey?> gate;
  _GatedKeys(this.gate);

  @override
  Future<ApprovalKey?> next() => gate.future;
}

/// An asker that records what it was handed and answers identically every
/// time — for asserting the vocabulary adapter.
class _FixedAsker implements ApprovalAsker {
  final ApprovalOutcome outcome;
  final List<PendingFileAsk> got = [];
  _FixedAsker(this.outcome);

  @override
  Future<ApprovalOutcome> ask(PendingFileAsk ask) async {
    got.add(ask);
    return outcome;
  }
}

ApprovalAskContext _ctx(PendingFileAsk ask) =>
    ApprovalAskContext(ask.op, ask.path, ask.reason);

/// The sandbox wired the way a host will: a [DialogApprover] over a queued
/// dialog asker with the scripted keys given per ask.
SandboxedFileSystem _wiredSandbox(String root, Directory tina,
        List<List<ApprovalKey?>> keysPerAsk) =>
    SandboxedFileSystem(
      const IoFileSystem(),
      workspaceRoot: root,
      tinaDir: tina,
      approver: DialogApprover(QueuedDialogAsker(
        dialogFor: (ask) => ApprovalDialog(null, ask: _ctx(ask)),
        keysFor: () => ScriptedKeySource(keysPerAsk.removeAt(0)),
      )).fn,
    );

void main() {
  late Directory tmp;
  late Directory tina;
  late Directory outside;
  late String target;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tina_tui_approver_');
    tina = Directory('${Directory.systemTemp.path}/tina_tui_tina_home');
    outside = Directory.systemTemp.createTempSync('tina_tui_victim_');
    target = p.join(outside.path, 'out.txt');
    addTearDown(() {
      tmp.deleteSync(recursive: true);
      outside.deleteSync(recursive: true);
    });
  });

  group('DialogApprover: the vocabulary adapter', () {
    final request = (op: FileOp.write, path: '/tmp/ws/../elsewhere/x.txt');

    test('allow comes back as Approval.yes, carrying the resolved ask',
        () async {
      final asker = _FixedAsker(const ApprovalOutcome(ApprovalDecision.allow));
      final got = await DialogApprover(asker).fn(request, 'outside the root');
      expect(got, Approval.yes);
      expect(asker.got.single.op, FileOp.write);
      expect(asker.got.single.path, request.path);
      expect(asker.got.single.reason, 'outside the root');
    });

    test('allowAlways comes back as Approval.always', () async {
      final asker =
          _FixedAsker(const ApprovalOutcome(ApprovalDecision.allowAlways));
      expect(await DialogApprover(asker).fn(request, 'why'),
          Approval.always);
    });

    test('deny throws the refusal the model reads, reason intact', () async {
      final asker = _FixedAsker(const ApprovalOutcome(ApprovalDecision.deny));
      await expectLater(
        DialogApprover(asker).fn(request, 'outside the root'),
        throwsA(isA<SandboxViolation>().having((e) => e.message, 'message',
            allOf(contains('outside the root'), contains('denied by the user')))),
      );
    });

    test('a cancelled dialog is a denial that says it was cancelled',
        () async {
      final asker = _FixedAsker(const ApprovalOutcome(
        ApprovalDecision.deny,
        reason: 'cancelled',
      ));
      await expectLater(
        DialogApprover(asker).fn(request, 'outside the root'),
        throwsA(isA<SandboxViolation>().having(
            (e) => e.message, 'message', contains('cancelled'))),
      );
    });
  });

  group('QueuedDialogAsker: one decision at a time', () {
    test('a second ask waits for the first to decide; answers stay paired',
        () async {
      final order = <String>[];
      final firstGate = Completer<ApprovalKey?>();
      var first = true;
      final asker = QueuedDialogAsker(
        dialogFor: (ask) {
          order.add('dialog:${ask.path}');
          return ApprovalDialog(null, ask: _ctx(ask));
        },
        keysFor: () {
          order.add('keys');
          if (first) {
            first = false;
            return _GatedKeys(firstGate);
          }
          return ScriptedKeySource([ApprovalKey.confirm]);
        },
      );

      final f1 = asker.ask(const PendingFileAsk(
        (op: FileOp.write, path: '/a/first.txt'),
        'outside the project root',
      ));
      final f2 = asker.ask(const PendingFileAsk(
        (op: FileOp.write, path: '/a/second.txt'),
        'outside the project root',
      ));

      // Let the queue run up to the gated first dialog.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        order,
        containsAllInOrder(['dialog:/a/first.txt', 'keys']),
        reason: 'the first dialog is open and asking for keys',
      );
      expect(order, isNot(contains('dialog:/a/second.txt')),
          reason: 'the second question must wait in line');

      firstGate.complete(ApprovalKey.confirm);
      expect((await f1).decision, ApprovalDecision.allowAlways,
          reason: 'each ask is answered by its own script');
      expect((await f2).decision, ApprovalDecision.allowAlways,
          reason: 'the second ask got its own one-key script, not the '
              'first\'s leftover state');
      expect(order.last, 'keys', reason: 'per ask: dialog first, then keys');
      expect(
        order,
        containsAllInOrder(
            ['dialog:/a/first.txt', 'keys', 'dialog:/a/second.txt']),
        reason: 'the queued dialog opens only after the first resolved',
      );
    });
  });

  group('wired to the sandbox', () {
    test('yes proceeds: the write runs', () async {
      final sandbox = _wiredSandbox(tmp.path, tina, [
        [ApprovalKey.confirm, ApprovalKey.confirm], // temp file, then target
      ]);
      final res = await WriteTool(fs: sandbox, workspaceRoot: tmp.path)
          .execute({'filePath': target, 'content': 'v1'});
      expect(res.isError, isFalse, reason: res.content);
      expect(File(target).existsSync(), isTrue);
    });

    test('no is refused: the write never happens, the reason travels',
        () async {
      final sandbox = _wiredSandbox(tmp.path, tina, [
        // deny on the first ask (the temp file of the atomic write): two
        // downs from `allow always` land on deny. The sibling-grant the
        // sandbox would add for an accepted temp file would cover the
        // target too, so denial must come before any acceptance.
        [ApprovalKey.down, ApprovalKey.down, ApprovalKey.confirm],
      ]);
      final res = await WriteTool(fs: sandbox, workspaceRoot: tmp.path)
          .execute({'filePath': target, 'content': 'v1'});
      expect(res.isError, isTrue);
      expect(res.content, contains('denied by the user'));
      expect(File(target).existsSync(), isFalse);
    });

    test('esc denies too: a cancelled dialog never allows', () async {
      final sandbox = _wiredSandbox(tmp.path, tina, [
        [ApprovalKey.cancel],
      ]);
      final res = await WriteTool(fs: sandbox, workspaceRoot: tmp.path)
          .execute({'filePath': target, 'content': 'v1'});
      expect(res.isError, isTrue);
      expect(res.content, contains('denied by the user'));
    });

    test('always proceeds and is remembered by the sandbox: the second '
        'identical write does not ask again', () async {
      var dialogs = 0;
      final sandbox = SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: tmp.path,
        tinaDir: tina,
        approver: DialogApprover(QueuedDialogAsker(
          dialogFor: (ask) {
            dialogs++;
            return ApprovalDialog(null, ask: _ctx(ask));
          },
          // allow always is the first choice when there is no tool call.
          keysFor: () => ScriptedKeySource([ApprovalKey.confirm]),
        )).fn,
      );
      final tool = WriteTool(fs: sandbox, workspaceRoot: tmp.path);
      final first = await tool.execute({'filePath': target, 'content': 'v1'});
      expect(first.isError, isFalse, reason: first.content);
      expect(dialogs, 1);

      // Same path again: the sandbox's grant short-circuits the ask —
      // remembering is the sandbox's business, not the dialog's.
      final second = await tool.execute({'filePath': target, 'content': 'v2'});
      expect(second.isError, isFalse, reason: second.content);
      expect(dialogs, 1, reason: 'the remembered grant skips the dialog');
      expect(File(target).readAsStringSync(), 'v2');
    });

    test('with no approver wired the refusal still happens and says so',
        () async {
      final sandbox = SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: tmp.path,
        tinaDir: tina,
      );
      final res = await WriteTool(fs: sandbox, workspaceRoot: tmp.path)
          .execute({'filePath': target, 'content': 'v1'});
      expect(res.isError, isTrue);
      expect(res.content, contains('no approver is wired'));
      expect(File(target).existsSync(), isFalse);
    });
  });
}
