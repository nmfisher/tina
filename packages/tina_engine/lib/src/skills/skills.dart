import 'dart:async';
import 'dart:convert';

import '../runtime/plugin.dart';
import '../agent/instructions.dart';
import 'skill.dart';

export 'skill.dart';

const skillsServiceKey = ServiceKey<Skills>('tina.engine.skills');

PluginDescriptor skillsPlugin() => PluginDescriptor(
      id: 'tina.engine.skills',
      provides: [skillsServiceKey],
      factory: FnPluginFactory((context) => Skills(context.scope)),
    );

/// Register a lazy source in the plugin's own scope. Its ID is unique within
/// that scope, using the existing plugin registration/lifetime machinery.
/// Dispose the handle to revoke it and cancel outstanding source operations.
/// Source-owned resources can be registered separately with context.own().
Registration registerSkillSource(
    PluginContext context, String id, SkillSource source) {
  final binding = _Source(source);
  return context.register(binding, id: id, dispose: binding.stop.complete);
}

/// Register an already-loaded skill through exactly the same scoped registry.
Registration registerSkill(PluginContext context, String id, Skill skill,
        {int rank = 250}) =>
    context.register(_StaticSkill(skill, rank), id: id);

class _Source {
  final SkillSource source;
  final stop = Completer<void>();
  _Source(this.source);
}

class _StaticSkill {
  final Skill skill;
  final int rank;
  _StaticSkill(this.skill, this.rank);
}

class _Owner {
  final PluginScope scope;
  final Contribution contribution;
  _Owner(this.scope, this.contribution);
  bool get live =>
      scope.isAdmitting && scope.contributions.contains(contribution);
}

class _Match {
  final _Owner owner;
  final SkillEntry entry;
  _Match(this.owner, this.entry);
}

class _Found {
  final List<_Owner> owners;
  final Map<String, _Match> entries;
  final bool complete;
  final List<String> failed;
  _Found(this.owners, this.entries, this.complete, this.failed);
}

/// A view of skill contributions visible from [scope]. No filesystem, model,
/// tool or UI dependencies. No discovery/body cache: every lookup sees source
/// changes, and removed registrations cannot serve late results.
class Skills {
  final PluginScope scope;
  Skills(this.scope);

  /// Service lookup inherits its original scope. Use a view for child agents
  /// so their private registrations can override the parent's skill names.
  Skills forScope(PluginScope child) {
    for (PluginScope? current = child;
        current != null;
        current = current.parent) {
      if (identical(current, scope)) return Skills(child);
    }
    throw ArgumentError('Skill view must belong to this scope or a descendant');
  }

  bool _allowed(SkillInfo info, SkillUse use) => switch (use) {
        SkillUse.internal => true,
        SkillUse.model => info.modelInvocable,
        SkillUse.user => info.userInvocable,
      };

  List<_Owner> _owners() {
    if (!scope.isAdmitting) throw StateError('Skill scope is closed');
    return [
      for (PluginScope? current = scope;
          current != null;
          current = current.parent)
        if (current.isAdmitting)
          for (final contribution in current.contributions)
            if (contribution.contribution is _Source ||
                contribution.contribution is _StaticSkill)
              _Owner(current, contribution),
    ];
  }

  SkillContext _context(_Source source, SkillContext caller) => SkillContext(
        cwd: caller.cwd,
        cancelSignal: Future.any([caller.cancelSignal, source.stop.future]),
      );

  bool _unchanged(List<_Owner> owners) {
    final current = _owners();
    return current.length == owners.length &&
        Iterable<int>.generate(current.length).every(
            (i) => identical(current[i].contribution, owners[i].contribution));
  }

  Future<_Found> _collect(SkillContext context) async {
    final owners = _owners();
    final failed = <String>[];
    var complete = true;
    final listings =
        await context.wait(() => Future.wait(owners.map((owner) async {
              final value = owner.contribution.contribution;
              if (value is _StaticSkill) {
                return SkillListing(
                    [SkillEntry(value.skill.info, rank: value.rank)]);
              }
              final source = value as _Source;
              final work = _context(source, context);
              try {
                final result = await work.wait(() => source.source.list(work));
                if (!result.complete) complete = false;
                return result;
              } catch (_) {
                context.check();
                complete = false;
                failed.add(owner.contribution.id);
                return SkillListing([], complete: false);
              } finally {
                work.cancel();
              }
            })));
    context.check();
    if (!_unchanged(owners)) complete = false;
    final matches = <String, _Match>{};
    for (var i = 0; i < owners.length; i++) {
      final owner = owners[i];
      if (!owner.live) {
        complete = false;
        continue;
      }
      for (final entry in listings[i].entries) {
        final previous = matches[entry.info.name];
        if (previous == null ||
            (identical(previous.owner.scope, owner.scope) &&
                entry.rank < previous.entry.rank)) {
          matches[entry.info.name] = _Match(owner, entry);
        }
      }
    }
    failed.sort();
    return _Found(owners, matches, complete, failed);
  }

  Future<SkillCatalog> list(
      {String? cwd,
      Future<void>? cancelSignal,
      SkillUse use = SkillUse.internal}) async {
    final context = SkillContext(cwd: cwd, cancelSignal: cancelSignal);
    try {
      final found = await _collect(context);
      final skills = found.entries.values
          .map((match) => match.entry.info)
          .where((info) => _allowed(info, use))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      return SkillCatalog(skills,
          complete: found.complete, failedSources: found.failed);
    } finally {
      context.cancel();
    }
  }

  /// Load the winning candidate only. Invocation filtering happens AFTER
  /// precedence, so a disallowed child skill never reveals a parent duplicate.
  /// Null means absent or disallowed. Incomplete discovery cannot prove absence.
  Future<Skill?> load(String name,
      {String? cwd,
      Future<void>? cancelSignal,
      SkillUse use = SkillUse.internal}) async {
    final context = SkillContext(cwd: cwd, cancelSignal: cancelSignal);
    try {
      final found = await _collect(context);
      if (!_unchanged(found.owners)) {
        throw StateError('Skill registrations changed during discovery; retry');
      }
      final match = found.entries[name];
      if (match == null) {
        if (!found.complete) throw StateError('Skill discovery is incomplete');
        return null;
      }
      if (!_allowed(match.entry.info, use)) return null;
      final value = match.owner.contribution.contribution;
      final Skill? result;
      if (value is _StaticSkill) {
        result = value.skill;
      } else {
        final source = value as _Source;
        final work = _context(source, context);
        try {
          result = await work.wait(() => source.source.load(match.entry, work));
        } finally {
          work.cancel();
        }
      }
      context.check();
      if (!scope.isAdmitting || !_unchanged(found.owners)) {
        throw StateError('Skill registrations changed during loading; retry');
      }
      if (result != null && result.info != match.entry.info) {
        throw StateError(
            'Loaded skill metadata differs from its catalog entry');
      }
      if (result != null) {
        final owner = match.owner.contribution;
        final info = result.info;
        notifyInstructions(
            scope,
            InstructionLoad(
                InstructionKind.skill,
                [
                  Instruction(
                    id: jsonEncode([
                      'skill',
                      owner.pluginId,
                      owner.id,
                      info.resourceBase?.toString(),
                      info.name
                    ]),
                    kind: InstructionKind.skill,
                    source: info.resourceBase,
                    scope: cwd == null ? null : Uri.directory(cwd),
                    text: result.content,
                    sourceText: result.content,
                  ),
                ],
                cwd: cwd));
      }
      return result;
    } finally {
      context.cancel();
    }
  }
}
