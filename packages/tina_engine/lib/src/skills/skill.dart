import 'dart:async';

/// Metadata safe to advertise without loading the instruction body.
final class SkillInfo {
  final String name;
  final String description;
  final bool modelInvocable;
  final bool userInvocable;
  final Uri? resourceBase;

  SkillInfo({
    required this.name,
    required this.description,
    this.modelInvocable = true,
    this.userInvocable = true,
    this.resourceBase,
  }) {
    if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name)) {
      throw ArgumentError.value(
          name, 'name', 'Expected a kebab-case skill name');
    }
    if (description.trim().isEmpty) {
      throw ArgumentError('A skill description is required');
    }
    if (resourceBase != null && !resourceBase!.isAbsolute) {
      throw ArgumentError('Skill resource base must be an absolute URI');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SkillInfo &&
      name == other.name &&
      description == other.description &&
      modelInvocable == other.modelInvocable &&
      userInvocable == other.userInvocable &&
      resourceBase == other.resourceBase;
  @override
  int get hashCode => Object.hash(
      name, description, modelInvocable, userInvocable, resourceBase);
}

/// A loaded instruction bundle. Resources are resolved by its source/consumer,
/// never read or executed by the registry. A base URI may be file, HTTPS, or a
/// provider-owned scheme; it does not grant permission to access resources.
final class Skill {
  final SkillInfo info;
  final String content;
  Skill({required this.info, required this.content}) {
    if (content.trim().isEmpty) throw ArgumentError('Empty skill instructions');
  }
}

/// A lazy source candidate. Lower rank wins within a scope; ties keep source
/// registration order, then entry order. The registry never interprets [key].
final class SkillEntry {
  final SkillInfo info;
  final Object? key;
  final int rank;
  const SkillEntry(this.info, {this.key, this.rank = 250});
}

/// A source may return usable candidates even when discovery is incomplete.
final class SkillListing {
  final List<SkillEntry> entries;
  final bool complete;
  SkillListing(Iterable<SkillEntry> entries, {this.complete = true})
      : entries = List.unmodifiable(entries);
}

/// Discovery and loading are independent; listing must not fetch full bodies.
abstract interface class SkillSource {
  Future<SkillListing> list(SkillContext context);
  Future<Skill?> load(SkillEntry entry, SkillContext context);
}

class SkillCancelled implements Exception {
  const SkillCancelled();
  @override
  String toString() => 'Skill lookup cancelled';
}

/// Caller workspace and cancellation, shared with source implementations.
/// Providers must cancel their own I/O when [cancelSignal] completes. The
/// registry also races waits so an uncooperative source cannot trap the caller.
final class SkillContext {
  final String? cwd;
  final _stop = Completer<void>();
  bool get isCancelled => _stop.isCompleted;
  Future<void> get cancelSignal => _stop.future;

  SkillContext({this.cwd, Future<void>? cancelSignal}) {
    cancelSignal?.then((_) => cancel(), onError: (Object _) => cancel());
  }

  void cancel() {
    if (!isCancelled) _stop.complete();
  }

  void check() {
    if (isCancelled) throw const SkillCancelled();
  }

  Future<T> wait<T>(Future<T> Function() work) async {
    // Observe a signal that was already completed before starting any work.
    await Future<void>.value();
    check();
    final value = await Future.any([
      Future<T>.sync(work),
      cancelSignal.then<T>((_) => throw const SkillCancelled()),
    ]);
    check();
    return value;
  }
}

enum SkillUse { internal, model, user }

final class SkillCatalog {
  final List<SkillInfo> skills;
  final bool complete;

  /// Contribution IDs only; source error text and bodies are never included.
  final List<String> failedSources;
  SkillCatalog(
    Iterable<SkillInfo> skills, {
    required this.complete,
    Iterable<String> failedSources = const [],
  })  : skills = List.unmodifiable(skills),
        failedSources = List.unmodifiable(failedSources);
}
