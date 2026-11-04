// Remembered MCP approvals as (server, tool) rules in the one scopes store:
// a rule answers any arguments for that tool on that server, at the scope it
// was remembered at; other tools still ask; the first grant-answered call of
// a turn prints one notice; revoking the rule makes the next call ask again.
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_tools/tina_tools.dart';

import 'dart:isolate';

import 'mcp_test.dart' show CallingProvider, Channel;

class _Terminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) async => '';
}

void main() {
  late Directory directory;
  late String fixture;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tina_mcp_rules_');
    final library = await Isolate.resolvePackageUri(
        Uri.parse('package:tina_mcp/tina_mcp.dart'));
    fixture = library!.resolve('../test/fixtures/server.py').toFilePath();
  });

  McpServerConfig config() => McpServerConfig('fixture', {
        'command': 'python3',
        'args': [fixture, '${directory.path}/events'],
      });

  tearDown(() => directory.deleteSync(recursive: true));

  ToolsPlugin tools() => ToolsPlugin(
      workspaceRoot: directory.path,
      tinaDir: Directory('${directory.path}/.tina'),
      hostEnvironment: {'HOME': directory.path, 'PATH': '/usr/bin:/bin'})
    ..modePolicy.persistentAccessGrants = true;

  test(
      'a session rule answers different arguments without asking; a different '
      'tool still asks; one notice per turn', () async {
    final store = CommandApprovalStore(
        workspace: directory.path, searchPath: '/usr/bin:/bin');
    var answer = ApprovalDecision.deny;
    var asked = 0;
    final provider = CallingProvider('mutate', input: {'value': 'a'});
    final channel = Channel()
      ..decide = (request) {
        if (request.operation == 'connect MCP server') {
          return ApprovalDecision.allow;
        }
        asked++;
        return answer;
      };
    final approvals = ApprovalsPlugin(channel: channel);
    final controls = tools();
    controls.modePolicy.approvals = approvals;
    final terminal = _Terminal();
    controls.modePolicy.terminal = terminal;
    controls.modePolicy.hasAccessGrant = store.coversAccess;
    controls.modePolicy.saveAccessGrant = (capability, target, decision) =>
        store.rememberAccess(
            capability, target,
            switch (decision) {
              ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
              ApprovalDecision.allowGlobal => CommandApprovalScope.global,
              _ => CommandApprovalScope.session,
            });
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [config()],
        approve: controls.modePolicy.request);
    addTearDown(() {
      plugin.shutdown();
      controls.closeSession();
      approvals.closeSession();
    });
    final loop =
        AgentLoop(provider: provider, plugins: [approvals, controls, plugin]);
    for (final p in [approvals, controls, plugin]) {
      loop.mountPlugin(p);
    }
    answer = ApprovalDecision.allowAlways;
    await loop.runTurn(const Input('remember the tool', id: 't1'));
    expect(asked, 1, reason: 'the first call asks');

    provider.next('mutate', {'value': 'completely different'});
    await loop.runTurn(const Input('different arguments', id: 't2'));
    expect(asked, 1, reason: 'the rule answers any arguments');
    expect(terminal.lines.where((line) => line.contains('allowed by rule')),
        contains(contains('fixture/mutate')),
        reason: 'the first rule-answered call of the turn prints a notice');

    provider.next('screenshot');
    await loop.runTurn(const Input('different tool', id: 't3'));
    expect(asked, 2, reason: 'a different tool on the same server asks');

    // Second rule-answered call in the same turn stays quiet.
    provider.next('mutate', {'value': 'again'});
    await loop.runTurn(const Input('same tool again', id: 't4'));
    expect(
        terminal.lines.where((line) => line.contains('allowed by rule')).length,
        2,
        reason: 'one notice per turn per rule');
  });

  test('a workspace rule persists in the store and revocation re-asks',
      () async {
    final file = File(
        '${directory.path}/.tina/approvals'); // The store file location is
    // chosen by the plugin wiring; here the store owns it explicitly.
    final store = CommandApprovalStore(
        workspace: directory.path,
        file: file,
        searchPath: '/usr/bin:/bin');
    var answer = ApprovalDecision.allowWorkspace;
    var asked = 0;
    final provider = CallingProvider('mutate');
    final channel = Channel()
      ..decide = (request) {
        if (request.operation == 'connect MCP server') {
          return ApprovalDecision.allow;
        }
        asked++;
        return answer;
      };
    final approvals = ApprovalsPlugin(channel: channel);
    final controls = tools();
    controls.modePolicy.approvals = approvals;
    controls.modePolicy.hasAccessGrant = store.coversAccess;
    controls.modePolicy.saveAccessGrant = (capability, target, decision) =>
        store.rememberAccess(
            capability, target,
            switch (decision) {
              ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
              ApprovalDecision.allowGlobal => CommandApprovalScope.global,
              _ => CommandApprovalScope.session,
            });
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [config()],
        approve: controls.modePolicy.request);
    addTearDown(() {
      plugin.shutdown();
      controls.closeSession();
      approvals.closeSession();
    });
    final loop =
        AgentLoop(provider: provider, plugins: [approvals, controls, plugin]);
    for (final p in [approvals, controls, plugin]) {
      loop.mountPlugin(p);
    }
    await loop.runTurn(const Input('remember at workspace scope', id: 't1'));
    expect(asked, 1);
    final rules = scopeRules(store);
    final rule = rules.singleWhere((rule) => rule.decidedBy == 'user');
    expect(rule.scope, CommandApprovalScope.workspace);
    expect(rule.display, contains('fixture/mutate'));

    provider.next('mutate', {'value': 'later'});
    await loop.runTurn(const Input('after restart-shaped reload', id: 't2'));
    expect(asked, 1, reason: 'the workspace rule survives in the store');

    store.revoke(rule.id);
    provider.next('mutate', {'value': 'after revoke'});
    await loop.runTurn(const Input('after revocation', id: 't3'));
    expect(asked, 2, reason: 'revoking the rule makes the next call ask');
  });

  test('an unanswered ask stores nothing', () async {
    final store = CommandApprovalStore(
        workspace: directory.path, searchPath: '/usr/bin:/bin');
    var answer = ApprovalDecision.deny;
    final provider = CallingProvider('mutate');
    final channel = Channel()
      ..decide = (request) => request.operation == 'connect MCP server'
          ? ApprovalDecision.allow
          : answer;
    final approvals = ApprovalsPlugin(channel: channel);
    final controls = tools();
    controls.modePolicy.approvals = approvals;
    controls.modePolicy.hasAccessGrant = store.coversAccess;
    controls.modePolicy.saveAccessGrant = (capability, target, decision) =>
        store.rememberAccess(capability, target, CommandApprovalScope.session);
    final plugin = McpPlugin(
        workingDirectory: directory.path,
        readServers: () => [config()],
        approve: controls.modePolicy.request);
    addTearDown(() {
      plugin.shutdown();
      controls.closeSession();
      approvals.closeSession();
    });
    final loop =
        AgentLoop(provider: provider, plugins: [approvals, controls, plugin]);
    for (final p in [approvals, controls, plugin]) {
      loop.mountPlugin(p);
    }
    await loop.runTurn(const Input('denied', id: 't1'));
    await loop.runTurn(const Input('denied again', id: 't2'));
    expect(scopeRules(store).where((rule) => rule.kind == ScopeRuleKind.access),
        isEmpty,
        reason: 'deny answers store no rule');
  });
}
