import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

void main() {
  test(
      'observers never supply approval authority and retained tickets stay scoped',
      () async {
    var suggestions = 0;
    final channel =
        AttachmentApprovalChannel(suggestCommandPattern: (_, __) async {
      suggestions++;
      return (pattern: '.*', explanation: null, failure: null);
    });
    final service = ApprovalsPlugin(channel: channel);
    final host = Host.start(HostConfig(
        workingDirectory: '.',
        plugins: [service, channel],
        providerFactory: (_) => ScriptedProvider([])));
    addTearDown(host.shutdown);
    final observer = host.connect(role: SessionRole.observer),
        controller = host.connect();
    addTearDown(observer.close);
    addTearDown(controller.close);
    final seen = <ApprovalQuestion>[], actionable = <ApprovalQuestion>[];
    final interaction = channel.interaction.forClient(observer.access);
    interaction.listen(seen.add);
    expect(await service.request(operation: 'run', target: 'alone', reason: ''),
        ApprovalDecision.deny);
    expect(seen, isEmpty);
    channel.interaction.forClient(controller.access).listen(actionable.add);
    final pending =
        service.request(operation: 'run', target: 'shared', reason: '');
    await Future<void>.delayed(Duration.zero);
    expect(seen.single.request.id, actionable.single.request.id);
    final denied = throwsA(isA<SessionAccessDenied>());
    expect(() => seen.single.respond(ApprovalDecision.allow), denied);
    expect(() => seen.single.respond(ApprovalDecision.deny), denied);
    await expectLater(
        interaction
            .forClient(const ClientAccess())
            .suggest(seen.single.request, Completer<void>().future),
        denied);
    expect(suggestions, 0);
    controller.close();
    expect(() => actionable.single.respond(ApprovalDecision.allow),
        throwsStateError);
    expect(service.pending, hasLength(1));
    final replacement = host.connect();
    addTearDown(replacement.close);
    final answers = <ApprovalQuestion>[];
    final release =
        channel.interaction.forClient(replacement.access).listen(answers.add);
    expect(answers.single.respond(ApprovalDecision.allow), isTrue);
    expect(await pending, ApprovalDecision.allow);
    release();
    expect(
        await service.request(
            operation: 'run', target: 'dead responder', reason: ''),
        ApprovalDecision.deny);
  });

  test('pending approvals survive detach and accept only one correlated answer',
      () async {
    final channel = AttachmentApprovalChannel();
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    addTearDown(channel.closeSession);
    expect(
        await service.request(operation: 'run', target: 'initial', reason: ''),
        ApprovalDecision.deny);
    final first = <ApprovalQuestion>[], second = <ApprovalQuestion>[];
    final detach = channel.interaction.listen(first.add);
    final pending =
        service.request(operation: 'run', target: 'command', reason: '');
    await Future<void>.delayed(Duration.zero);
    detach();
    var answered = false;
    unawaited(pending.then((_) => answered = true));
    await Future<void>.delayed(Duration.zero);
    expect(answered, false);
    channel.interaction.listen(second.add);
    expect(second.single.request.id, first.single.request.id);
    expect(second.single.respond(ApprovalDecision.allow), true);
    expect(first.single.respond(ApprovalDecision.deny), false);
    expect(await pending, ApprovalDecision.allow);
    expect(channel.interaction.pending, isEmpty);
  });

  test(
      'views receive immutable details and shutdown invalidates all responders',
      () async {
    final channel = AttachmentApprovalChannel();
    final service = ApprovalsPlugin(channel: channel);
    final questions = <ApprovalQuestion>[];
    channel.interaction.listen(questions.add);
    final pending = service
        .request(operation: 'run', target: 'command', reason: '', details: {
      'tool': {
        'input': [1]
      }
    });
    await Future<void>.delayed(Duration.zero);
    expect(
        () => (questions.single.request.details['tool'] as Map)['input'].add(2),
        throwsUnsupportedError);
    channel.closeSession();
    expect(await pending, ApprovalDecision.deny);
    expect(questions.single.respond(ApprovalDecision.allow), false);
    service.closeSession();
  });
}
