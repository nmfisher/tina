import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';

void main() {
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
