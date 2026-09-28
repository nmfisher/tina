import 'dart:io';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'release_checker.dart';
import 'updater.dart';

PluginDefinition<C> updateDefinition<C>({
  required String Function(C) version,
  required Terminal Function(C) terminal,
}) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/update',
        dependency: approvalRequester,
        create: (context, approvals) => UpdatePlugin(
            currentVersion: version(context),
            terminal: terminal(context),
            approvals: approvals));

/// All delivery channels use the same prepared update and approval contract.
final class UpdatePlugin extends AgentPlugin {
  UpdatePlugin(
      {required this.currentVersion,
      required this.terminal,
      required this.approvals,
      ReleaseChecker? checker,
      Future<UpdatePrepareOutcome> Function(ReleaseInfo, void Function(String))?
          prepare})
      : checker = checker ??
            ReleaseChecker(
                env: Platform.environment, currentVersion: currentVersion),
        _prepare = prepare ??
            ((release, notice) => prepareUpdate(release, notice: notice));
  final String currentVersion;
  final Terminal terminal;
  final ApprovalRequester approvals;
  final ReleaseChecker checker;
  final Future<UpdatePrepareOutcome> Function(
      ReleaseInfo, void Function(String)) _prepare;
  bool _busy = false;
  bool _closed = false;
  @override
  String get id => 'tina/update';
  @override
  void mountOn(AgentLoop loop) {
    cleanupStaleOldBundle();
  }

  @override
  List<Command> get commands => [
        Command(
            name: 'update',
            description:
                'Check for an update, or /update install to prepare and approve installation.',
            complete: (prefix) => ['check', 'install']
                .where((word) => word.startsWith(prefix))
                .toList(),
            handler: _run)
      ];

  Future<void> _run(String argument) async {
    if (_closed || _busy) return;
    if (!['', 'check', 'install'].contains(argument)) {
      terminal.writeln('usage: /update [check|install]');
      return;
    }
    _busy = true;
    try {
      terminal.writeln('Checking for updates (installed: $currentVersion)…');
      final release = await checker.fetchLatest();
      if (_closed) return;
      if (release == null) {
        terminal.writeln(
            'Update check failed: ${checker.lastMiss?.detail ?? 'no release information'}.');
        return;
      }
      if (!isNewer(release.tag, current: currentVersion)) {
        terminal.writeln('Already up to date ($currentVersion).');
        return;
      }
      terminal.writeln('Available: ${release.tag}. ${release.releaseUrl}');
      if (argument != 'install') {
        terminal.writeln(
            'Run /update install to download, verify and approve the update.');
        return;
      }
      final prepared = await _prepare(release, terminal.writeln);
      switch (prepared) {
        case UpdatePrepareReady(:final update):
          try {
            if (_closed) return;
            final decision = await approvals.request(
                operation: 'install update',
                target: update.bundleRoot,
                reason:
                    'Verified ${release.tag}. Replace the installed tina bundle? Restart is required.');
            if (_closed || decision == ApprovalDecision.deny) {
              terminal.writeln('Update cancelled.');
              return;
            }
            await update.install(notice: terminal.writeln);
          } finally {
            update.discard();
          }
        case UpdatePrepareManualRequired() || UpdatePrepareUnsupported():
          terminal.writeln(
              'Install manually from ${release.releaseUrl}; this process is not a supported writable bundle install.');
        case UpdatePrepareFailure():
          terminal
              .writeln('Update preparation failed; installation unchanged.');
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void closeSession() {
    _closed = true;
    checker.close();
  }
}
