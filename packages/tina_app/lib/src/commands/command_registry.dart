import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import 'command_context.dart';

/// One command contribution. Names include the leading slash; aliases share
/// one handler and appear in completion, while help shows the primary name.
class Command {
  final List<String> names;
  final String argsHint;
  final String summary;
  final int helpOrder;
  final String? helpContinuation;
  final bool inHelp;
  final String? feature;
  final Future<CmdResult> Function(CommandCall) handler;
  Command({
    required Iterable<String> names,
    this.argsHint = '',
    required this.summary,
    this.helpOrder = 100,
    this.helpContinuation,
    this.inHelp = true,
    this.feature,
    required this.handler,
  }) : names = List.unmodifiable(names) {
    if (this.names.isEmpty ||
        this.names.toSet().length != this.names.length ||
        this.names.any(
          (name) => !RegExp(r'^/[a-z][a-z0-9-]*$').hasMatch(name),
        )) {
      throw ArgumentError('Invalid command names');
    }
  }
  String get primary => names.first;
}

/// Pins output and cancellation to the conversation that invoked the command.
/// Late writes after cancellation are ignored. A command returns CmdRun to
/// submit a prompt through the normal input-routing and agent path.
class CommandCall {
  final String line;
  final String conversationId;
  final HostInterface _host;
  final _cancel = Completer<void>();
  bool _finished = false;
  CommandCall._(
    this.line,
    this.conversationId,
    this._host,
    Future<void>? signal,
  ) {
    signal?.then(
      (_) {
        if (!_cancel.isCompleted) _cancel.complete();
      },
      onError: (Object _) {
        if (!_cancel.isCompleted) _cancel.complete();
      },
    );
  }
  String get word => line.split(RegExp(r'\s+')).first;
  String get arguments => line.substring(word.length).trim();
  Future<void> get cancelSignal => _cancel.future;
  bool get isCancelled => _cancel.isCompleted;
  void write(String text, {HostMessageStyle style = HostMessageStyle.normal}) {
    if (!isCancelled && !_finished) _host.showMessage(text, style: style);
  }
}

/// Live command view over a plugin scope and its borrowed parents. The same
/// view drives dispatch, help and completion. Duplicate names are errors,
/// never silent overrides (even when contributions have different IDs).
class CommandRegistry {
  final PluginScope scope;
  final Set<String> hiddenFeatures;
  CommandRegistry(this.scope, {Set<String> hiddenFeatures = const {}})
    : hiddenFeatures = Set.unmodifiable(hiddenFeatures) {
    _entries();
  }

  List<({Command command, Contribution contribution, PluginScope owner})>
  _entries() {
    final entries =
        <({Command command, Contribution contribution, PluginScope owner})>[];
    final names = <String, String>{};
    for (PluginScope? owner = scope; owner != null; owner = owner.parent) {
      if (!owner.isAdmitting)
        throw StateError('Command plugin scope is closed');
      for (final contribution in owner.contributions) {
        final command = contribution.contribution;
        if (command is! Command) continue;
        for (final name in command.names) {
          final previous = names[name];
          if (previous != null) {
            throw StateError(
              'Duplicate command $name from $previous and ${contribution.pluginId}',
            );
          }
          names[name] = contribution.pluginId;
        }
        if (command.feature != null && hiddenFeatures.contains(command.feature))
          continue;
        entries.add((
          command: command,
          contribution: contribution,
          owner: owner,
        ));
      }
    }
    return entries;
  }

  List<Command> get commands => [for (final entry in _entries()) entry.command];
  List<String> get allNames => [
    for (final command in commands) ...command.names,
  ];
  Command? lookup(String name) =>
      commands.where((c) => c.names.contains(name)).firstOrNull;

  String renderHelp() {
    final out = StringBuffer('Commands:\n');
    final visible = commands.where((c) => c.inHelp).toList()
      ..sort((a, b) => a.helpOrder.compareTo(b.helpOrder));
    for (final command in visible) {
      final label = '${command.primary} ${command.argsHint}'.trim();
      out.write(
        '  ${label.padRight(15)}${label.length >= 15 ? ' ' : ''}${command.summary}\n',
      );
      if (command.helpContinuation != null) {
        out.write('  ${''.padRight(15)}${command.helpContinuation}\n');
      }
    }
    out.write("ESC cancels the active session's in-flight response.\n");
    return out.toString();
  }

  Future<CmdResult> dispatch(
    String line, {
    required HostInterface host,
    required String conversationId,
    Future<void>? cancelSignal,
    Map<String, FutureOr<void> Function()> hooks = const {},
  }) async {
    final trimmed = line.trim();
    final word = trimmed.split(RegExp(r'\s+')).first;
    if (!word.startsWith('/')) return const CmdNotCommand();
    final call = CommandCall._(trimmed, conversationId, host, cancelSignal);
    try {
      final entry = _entries()
          .where((e) => e.command.names.contains(word))
          .firstOrNull;
      if (entry == null) {
        call.write('$word: unknown command\n', style: HostMessageStyle.error);
        return const CmdHandled(failed: true);
      }
      call.write('$trimmed\n', style: HostMessageStyle.user);
      host.showSeparator();
      return await Future.any<CmdResult>([
        Future<CmdResult>(() async {
          if (call.isCancelled) return const CmdHandled();
          await hooks[word]?.call();
          if (call.isCancelled) return const CmdHandled();
          if (!entry.owner.isAdmitting ||
              !entry.owner.contributions.contains(entry.contribution)) {
            throw StateError(
              'Command plugin ${entry.contribution.id} was removed',
            );
          }
          final result = await entry.command.handler(call);
          if (call.isCancelled) return const CmdHandled();
          if (!entry.owner.isAdmitting ||
              !entry.owner.contributions.contains(entry.contribution)) {
            throw StateError(
              'Command plugin ${entry.contribution.id} was removed',
            );
          }
          return result;
        }),
        call.cancelSignal.then((_) => const CmdHandled()),
      ]);
    } catch (e) {
      call.write('$word failed: $e\n', style: HostMessageStyle.error);
      return const CmdHandled(failed: true);
    } finally {
      call._finished = true;
    }
  }
}
