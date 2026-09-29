import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_grok_guard/tina_grok_guard.dart';

class Channel implements ApprovalChannel {
  final tickets = <ApprovalTicket>[];
  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    tickets.add(ticket);
  }

  Future<ApprovalTicket> ticket([int index = 0]) async {
    while (tickets.length <= index) {
      await Future<void>.delayed(Duration.zero);
    }
    return tickets[index];
  }
}

class Broken implements ApprovalRequester {
  @override
  Future<ApprovalDecision> request(
          {required String operation,
          required String target,
          required String reason,
          ApprovalKind kind = ApprovalKind.permission, Map<String, Object?> details = const {}}) async =>
      throw StateError('offline');
}

void main() {
  late ScriptedProvider provider;
  late Channel channel;
  late ApprovalsPlugin approvals;
  late AgentLoop loop;
  setUp(() {
    provider = ScriptedProvider([scriptedReply('ok'), scriptedReply('ok')]);
    channel = Channel();
    approvals = ApprovalsPlugin(channel: channel);
    loop = AgentLoop(
        provider: provider, plugins: [approvals, GrokGuardPlugin(approvals)]);
  });
  tearDown(() => approvals.closeSession());
  test('ordinary input goes straight through', () async {
    expect((await loop.runTurn(const Input('hello', id: '1'))).stopReason,
        StopReason.complete);
    expect(channel.tickets, isEmpty);
    expect(provider.callCount, 1);
  });
  test('case-insensitive substring match waits; Yes sends the original message',
      () async {
    const text = 'please discuss Grokking';
    final turn = loop.runTurn(const Input(text, id: '1'));
    final ticket = await channel.ticket().timeout(const Duration(seconds: 1));
    expect(ticket.request.reason, GrokGuardPlugin.question);
    expect(ticket.request.kind, ApprovalKind.confirmation);
    expect(provider.callCount, 0);
    ticket.respond(ApprovalDecision.allow);
    expect((await turn).stopReason, StopReason.complete);
    expect(
        (provider.requests.single.messages.last.content.single as TextBlock)
            .text,
        text);
    final again = loop.runTurn(const Input('grok again', id: '2'));
    (await channel.ticket(1)).respond(ApprovalDecision.deny);
    await again;
    expect(provider.callCount, 1);
  });
  test('No cancels; denied input never leaks into a later request or resume',
      () async {
    final turn = loop.runTurn(const Input('blocked grok', id: '1'));
    (await channel.ticket()).respond(ApprovalDecision.deny);
    expect((await turn).stopReason, StopReason.cancelled);
    expect(provider.callCount, 0);
    expect(loop.log.whereType<MessageAppendedEntry>(), isEmpty);
    expect(
        loop.log.whereType<InputRecordedEntry>().single.text, 'blocked grok');
    await loop.runTurn(const Input('safe', id: '2'));
    expect(
        jsonEncode(
            provider.requests.single.messages.map((m) => m.toJson()).toList()),
        isNot(contains('blocked grok')));
    final restored =
        AgentLoop(provider: provider, plugins: [], seedLog: loop.log);
    expect(
        jsonEncode(restored.derive().messages.map((m) => m.toJson()).toList()),
        isNot(contains('blocked grok')));
  });
  test('turn cancellation dismisses approval; a late Yes cannot send',
      () async {
    final turn = loop.runTurn(const Input('grok', id: '1'));
    final ticket = await channel.ticket();
    loop.cancel('escape');
    expect((await turn.timeout(const Duration(seconds: 1))).stopReason,
        StopReason.cancelled);
    expect(ticket.respond(ApprovalDecision.allow), false);
    expect(provider.callCount, 0);
    await loop.runTurn(const Input('safe', id: '2'));
    expect(provider.callCount, 1);
  });
  test('a failing approval requester cancels rather than sending', () async {
    final broken =
        AgentLoop(provider: provider, plugins: [GrokGuardPlugin(Broken())]);
    expect((await broken.runTurn(const Input('grok', id: '1'))).stopReason,
        StopReason.cancelled);
    expect(provider.callCount, 0);
  });
  test('expiry and absent approval delivery deny matching input', () async {
    final service = ApprovalsPlugin(
        channel: Channel(), timeout: const Duration(milliseconds: 10));
    addTearDown(service.closeSession);
    final guarded = AgentLoop(
        provider: provider, plugins: [service, GrokGuardPlugin(service)]);
    expect((await guarded.runTurn(const Input('grok', id: '1'))).stopReason,
        StopReason.cancelled);
    expect(provider.callCount, 0);
  });
}
