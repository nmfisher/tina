import 'dart:io';
import 'dart:async';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'release_checker.dart';
import 'updater.dart';
import 'update_status.dart';

PluginDefinition<C> updateDefinition<C>({
  required String Function(C) version,
  required Terminal Function(C) terminal,
  void Function(String)? Function(C)? restart,
}) =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/update',
        dependency: approvalRequester,
        provides: [updateStatusSource],
        create: (context, approvals) => UpdatePlugin(
            currentVersion: version(context),
            terminal: terminal(context),
            approvals: approvals,
            restart: restart?.call(context)),
        description:
            'Checks for new releases and installs an update after approval.');

/// All delivery channels use the same prepared update and approval contract.
final class UpdatePlugin extends AgentPlugin implements UpdateStatusSource {
  UpdatePlugin(
      {required this.currentVersion,
      required this.terminal,
      required this.approvals,
      this.restart,
      ReleaseChecker? checker,
      bool? backgroundEnabled,
      Future<UpdatePrepareOutcome> Function(ReleaseInfo, void Function(String))?
          prepare})
      : backgroundEnabled = backgroundEnabled ??
            Platform.environment['COCOON_UPDATE_CHECK'] != '0',
        checker = checker ??
            ReleaseChecker(
                env: Platform.environment, currentVersion: currentVersion),
        _prepare = prepare ??
            ((release, notice) => prepareUpdate(release, notice: notice));
  @override
  final String currentVersion;
  final Terminal terminal;
  final ApprovalRequester approvals;

  /// The application closes its terminal and sessions before relaunching.
  final void Function(String bundleRoot)? restart;
  final ReleaseChecker checker;
  final bool backgroundEnabled;
  final _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => _changes.stream;
  @override
  UpdateStatus get status => _status;
  UpdateStatus _status = const UpdateStatus(UpdatePhase.current);
  Future<void>? _background;

  void _setStatus(UpdateStatus value) {
    if (_closed) return;
    _status = value;
    _changes.add(null);
  }

  @override
  Future<void> checkInBackground() {
    if (_closed || !backgroundEnabled) return Future.value();
    return _background ??= _checkBackground();
  }

  Future<void> _checkBackground() async {
    // Explicit checks own the checker while their command is running.
    if (_busy) return;
    _setStatus(const UpdateStatus(UpdatePhase.checking));
    try {
      _accept(await checker.checkWithRevalidate(), background: true);
    } catch (error) {
      _setStatus(UpdateStatus(UpdatePhase.failed, reason: '$error'));
    }
  }

  void _accept(ReleaseInfo? release, {bool background = false}) {
    if (release != null && isNewer(release.tag, current: currentVersion)) {
      _setStatus(UpdateStatus(UpdatePhase.available, tag: release.tag));
    } else if (checker.lastMiss case final miss?) {
      _setStatus(UpdateStatus(UpdatePhase.failed,
          reason: miss.detail, tag: release?.tag));
    } else if (background && checker.deferUntil != null) {
      _setStatus(UpdateStatus(UpdatePhase.deferred,
          until: checker.deferUntil, tag: release?.tag));
    } else {
      _setStatus(UpdateStatus(
          release == null ? UpdatePhase.failed : UpdatePhase.current,
          reason: release == null ? 'no release information' : null));
    }
  }

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
      await _background;
      if (_closed) return;
      _setStatus(const UpdateStatus(UpdatePhase.checking));
      terminal.writeln('Checking for updates (installed: $currentVersion)…');
      final release = await checker.fetchLatest();
      if (_closed) return;
      _accept(release);
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
            final result = await update.install(notice: terminal.writeln);
            if (result == UpdateResult.success && !_closed && restart != null) {
              final answer = await approvals.request(
                  operation: 'Restart tina?',
                  target: update.bundleRoot,
                  reason: 'Update installed successfully. Restart tina now?',
                  kind: ApprovalKind.confirmation);
              if (!_closed && answer == ApprovalDecision.allow) {
                restart!(update.bundleRoot);
              }
            }
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
    } catch (error) {
      _setStatus(UpdateStatus(UpdatePhase.failed, reason: '$error'));
      rethrow;
    } finally {
      _busy = false;
    }
  }

  @override
  void closeSession() {
    _closed = true;
    checker.close();
    unawaited(_changes.close());
  }
}
