/// Named timers: the engine-side service (spec §4, docs/proposals/timer_system.md).
///
/// The service owns the schedule (fixed grid with busy-collapse), the per-timer
/// counters, the runaway guard, and the export/restore snapshots. It never
/// builds tool text and never touches disk — tools (§6) translate outcomes into
/// `ToolResult`s, and the persistence package (§10) owns the sidecar file.
///
/// Concurrency model (§4.3): Dart's own event loop, no locks. One armed
/// `Timer` per active, non-suspended timer; fires execute as agent turns,
/// which are already serialized per conversation.
library;

import 'dart:async';

/// Creates the underlying one-shot `Timer`. Production passes nothing (real
/// `Timer`); tests inject a fake that never sleeps.
typedef TimerFactory = Timer Function(
    Duration duration, void Function() callback);

/// Identifies one fire of one timer across the entry's lifecycle (§7).
///
/// Acks carry the id they were issued for: every `set` replacement bumps the
/// entry's generation, and every restore assigns a fresh one, so a completion
/// from an old lifecycle can never ack (or be acked as) a newer timer with
/// the same name, and a stale in-flight fire can never attach to a
/// replacement.
class TimerFireId {
  final String name;

  /// Lifecycle of the entry this fire belongs to: 0 for a freshly `set`
  /// entry, bumped on every replace, fresh (unique) after each restore.
  final int generation;

  /// 1-based fire number within the generation (matches `fireCount` at the
  /// moment of the tick).
  final int fireNumber;

  const TimerFireId({
    required this.name,
    required this.generation,
    required this.fireNumber,
  });

  @override
  bool operator ==(Object other) =>
      other is TimerFireId &&
      other.name == name &&
      other.generation == generation &&
      other.fireNumber == fireNumber;

  @override
  int get hashCode => Object.hash(name, generation, fireNumber);

  @override
  String toString() => '$name#$generation/$fireNumber';
}

/// Called when a timer's tick lands while the timer is [TimerEntryState.idle]:
/// the app wires this to the controller seam that starts a real agent turn
/// (§7). The app must pass [TimerFireId] back to [TimerService.ackStarted] /
/// [TimerService.ackFinished] so the ack binds to this exact lifecycle.
typedef TimerFireCallback = void Function(TimerFireId fire);

/// Called for operator-visible notices: suspension warnings (§8, `warning`
/// true) and busy-collapse skip lines (§4.4, `warning` false). The app wires
/// this to `host.showMessage`.
typedef TimerNoticeCallback = void Function(String text,
    {required bool warning});

/// Active-timer cap, runtime-wide (§4.4 step 5). Suspended timers hold their
/// slot; replacing an existing name never double-counts.
const int kMaxActiveTimers = 8;

/// Shortest interval a timer may run at. Shorter requests clamp here (§5).
const Duration kMinTimerInterval = Duration(seconds: 30);

/// Longest interval a timer may run at. Longer requests clamp here (§5).
const Duration kMaxTimerInterval = Duration(hours: 24);

/// Consecutive aborted (cancelled or aborted-turn) fires after which a timer
/// is suspended (§8).
const int kMaxTimerFiresBeforeSuspend = 6;

/// Longest check instruction the `set_timer` tool accepts (§6.1).
const int kMaxTimerInstructionChars = 2000;

/// What to run, how often, and for how long (§4.1). The tool layer validates
/// and clamps; the service trusts these fields.
class TimerSpec {
  /// Unique timer name. Validated by the tool layer, trusted here.
  final String name;

  /// Grid interval; already clamped by the tool layer.
  final Duration interval;

  /// Self-contained check instruction replayed verbatim as a turn prompt.
  final String instruction;

  /// Sugar for `maxFires == 1`; mutually exclusive with [maxFires].
  final bool once;

  /// Fire cap; null = unlimited (recurring).
  final int? maxFires;

  const TimerSpec({
    required this.name,
    required this.interval,
    required this.instruction,
    this.once = false,
    this.maxFires,
  });
}

/// Where an entry is in its fire cycle (§4.2). `queued` = the tick fired and
/// the app was notified; `running` = the app acked the turn as started.
enum TimerEntryState { idle, queued, running }

/// Point-in-time view of one timer, for `list()` / `list_timers` (§4.1).
class TimerSnapshot {
  final String name;
  final Duration interval;
  final String instruction;
  final int fireCount;
  final bool once;
  final int? maxFires;

  /// True after [kMaxTimerFiresBeforeSuspend] consecutive aborted fires (§8).
  /// A suspended timer holds its cap slot until cancelled or replaced.
  final bool suspended;
  final int consecutiveAbortedFires;
  final TimerEntryState state;

  /// Next grid point, or null while a fire is in flight (queued/running —
  /// the anchor still advances underneath) or while suspended (disarmed).
  final DateTime? nextFireAt;

  const TimerSnapshot({
    required this.name,
    required this.interval,
    required this.instruction,
    required this.fireCount,
    required this.once,
    required this.maxFires,
    required this.suspended,
    required this.consecutiveAbortedFires,
    required this.state,
    required this.nextFireAt,
  });
}

/// Result of [TimerService.set]. The tools translate these into `ToolResult`
/// text (§6.1); the service never words tool output itself.
sealed class TimerSetOutcome {
  const TimerSetOutcome();
}

/// A new entry was created (name was free and under the cap).
class TimerSetCreated extends TimerSetOutcome {
  const TimerSetCreated();
}

/// An existing entry with this name was replaced: new interval/instruction,
/// fresh counters, suspension cleared. Never counts twice against the cap.
class TimerSetReplaced extends TimerSetOutcome {
  const TimerSetReplaced();
}

/// The set was refused; [reason] is short, tool-facing text (§6.1).
class TimerSetRejected extends TimerSetOutcome {
  final String reason;
  const TimerSetRejected(this.reason);
}

/// One live timer's mutable state (§4.2). Private; snapshots and export maps
/// are the outside world's view.
class _TimerEntry {
  final String name;
  final String? sessionId;
  Duration interval;
  String instruction;
  bool once;
  int? maxFires;
  int fireCount = 0;
  int consecutiveAbortedFires = 0;
  bool suspended = false;
  TimerEntryState state = TimerEntryState.idle;

  /// Lifecycle version of this entry: 0 when first `set`, +1 on every
  /// replacement. Rides on every [TimerFireId] so an ack from an older
  /// lifecycle (a check still running when the name was re-set) can never
  /// complete a newer timer under the same name.
  int generation = 0;

  /// The in-flight fire this entry is queued/running for, if any. Acks that
  /// do not match it exactly are ignored — a stale turn's completion cannot
  /// settle (or suspend, or exhaust) a fire it does not belong to.
  TimerFireId? currentFire;

  /// The fixed-grid schedule position. Advances from the PREVIOUS anchor,
  /// never from actual execution time (§4.4) — a slow check cannot drift it.
  DateTime nextAnchor;

  /// The currently armed one-shot timer, if any.
  Timer? timer;

  /// Whether the busy-collapse notice already fired for the current in-flight
  /// window (from fire to ackFinished, at most one skip line — §4.4 step 2).
  bool collapseNoticeShown = false;

  /// The fire number this entry's [currentFire] was issued for, or null when
  /// [currentFire] is null / doesn't match this generation. Guards
  /// [TimerService.ackFinished] against settling a stale fire.
  int? fireNumberFor(TimerFireId fire) =>
      currentFire == fire ? fire.fireNumber : null;

  _TimerEntry({
    required this.name,
    required this.sessionId,
    required this.interval,
    required this.instruction,
    required this.once,
    required this.maxFires,
    required this.nextAnchor,
  });
}

/// The timer system proper (§4). See the library docs for the split of
/// responsibilities between this class, the tools, and the sidecar store.
class TimerService {
  final TimerFireCallback onFire;
  final TimerNoticeCallback onNotice;
  final TimerFactory _timerFactory;
  final DateTime Function() _clock;
  final String? Function()? _currentSessionId;
  final Map<String, _TimerEntry> _entries = {};
  bool _disposed = false;

  /// Source of fresh generations for restored entries (unique across the
  /// service's lifetime, never colliding with `set`-installed generations).
  int _nextRestoreGeneration = 1 << 30;

  /// Called after every state change that alters durable state — the same
  /// moments that bump [revision] (set, cancel, replace, expiry/suspension
  /// inside [ackFinished], [restoreState]) — with the ids of the sessions
  /// whose saved-timer set changed (the app marks those sessions' sidecars
  /// for rewrite; null-owner entries are unplaceable and skipped). The app
  /// wires this to write-through persistence (§10 leg 2) so a sidecar flush
  /// follows every mutation instead of only timer fires.
  final void Function(Set<String> sessionIds)? onMutation;

  /// Monotonic mutation counter (leg-2, §10 write-through): bumped by every
  /// state change that changes durable state — set, cancel, expiry or
  /// suspension inside [ackFinished], and [restoreState] — never by plain
  /// ticks. The app compares it against its last-flushed value to decide
  /// whether a sidecar rewrite is due.
  int revision = 0;

  TimerService({
    required this.onFire,
    required this.onNotice,
    this.onMutation,
    TimerFactory? timerFactory,
    DateTime Function()? clock,
    String? Function()? currentSessionId,
  })  : _timerFactory = timerFactory ?? _defaultTimerFactory,
        _clock = clock ?? DateTime.now,
        _currentSessionId = currentSessionId;

  /// Registers (or replaces) a timer (§4.4 steps 1 and 6).
  ///
  /// A new name counts against [kMaxActiveTimers]; replacing an existing name
  /// never does. Replacement installs the new interval/instruction with fresh
  /// [TimerSpec.once]/[TimerSpec.maxFires], zeroes `fireCount` and
  /// `consecutiveAbortedFires`, and clears suspension — the documented path
  /// back from a suspended timer (§8).
  TimerSetOutcome set(TimerSpec spec) {
    final existing = _entries[spec.name];
    if (existing == null && _entries.length >= kMaxActiveTimers) {
      return TimerSetRejected('$kMaxActiveTimers-timer limit reached');
    }
    final now = _clock();
    final replaced = existing != null;
    if (replaced) {
      _disarm(existing);
      existing
        ..interval = spec.interval
        ..instruction = spec.instruction
        ..once = spec.once
        ..maxFires = spec.maxFires
        ..fireCount = 0
        ..consecutiveAbortedFires = 0
        ..suspended = false
        ..state = TimerEntryState.idle
        ..collapseNoticeShown = false
        ..currentFire = null
        ..generation += 1
        ..nextAnchor = now.add(spec.interval);
    } else {
      _entries[spec.name] = _TimerEntry(
        name: spec.name,
        sessionId: _currentSessionId?.call(),
        interval: spec.interval,
        instruction: spec.instruction,
        once: spec.once,
        maxFires: spec.maxFires,
        nextAnchor: now.add(spec.interval),
      );
    }
    _arm(_entries[spec.name]!, now);
    revision++;
    onMutation?.call({
      if (_entries[spec.name]!.sessionId case final String owner) owner,
    });
    return replaced ? const TimerSetReplaced() : const TimerSetCreated();
  }

  /// Disarms and removes a timer. False when the name is unknown. Any fire
  /// already delivered for this name is detached: the app calls
  /// [cancelActiveFires] at teardown so an in-flight prompt is told not to
  /// run (and cannot ack back into a dead entry).
  bool cancel(String name) {
    final entry = _entries.remove(name);
    if (entry == null) return false;
    _disarm(entry);
    revision++;
    onMutation?.call({
      if (entry.sessionId case final String owner) owner,
    });
    return true;
  }

  /// Snapshot of every live entry, in insertion order, including suspended
  /// ones (they hold their cap slot, §4.4 step 7).
  List<TimerSnapshot> list() =>
      [for (final e in _entries.values) _snapshotOf(e)];

  /// The app acks a fire-turn's start (§7.2). No-op unless [fire] is the
  /// entry's current in-flight fire — defensive against a stale or
  /// mis-attributed turn.
  void ackStarted(TimerFireId fire) {
    final entry = _entries[fire.name];
    if (entry == null || entry.currentFire != fire) return;
    if (entry.state == TimerEntryState.queued) {
      entry.state = TimerEntryState.running;
    }
  }

  /// The app acks a fire-turn's end (§7.3). [aborted] = the turn was
  /// ESC-cancelled or aborted (provider, transport, budget, steps).
  ///
  /// No-op unless [fire] is the entry's current in-flight fire: a completion
  /// from an older lifecycle (the name was re-set or restored meanwhile) or a
  /// duplicate can never settle — let alone suspend or exhaust — a newer
  /// timer that happens to share the name.
  ///
  /// Counts consecutive aborts and suspends at [kMaxTimerFiresBeforeSuspend]
  /// (§8); removes the entry when its fire cap is used up (`once` or
  /// `fireCount == maxFires`); otherwise re-arms on the grid (§4.4 steps 3-5).
  /// Tolerated no-op for unknown names and states not in flight.
  void ackFinished(TimerFireId fire, {required bool aborted}) {
    final entry = _entries[fire.name];
    if (entry == null || entry.currentFire != fire) return;
    if (entry.fireNumberFor(fire) == null) return;
    if (entry.state != TimerEntryState.queued &&
        entry.state != TimerEntryState.running) {
      return;
    }
    entry.currentFire = null;
    final now = _clock();
    entry.state = TimerEntryState.idle;
    entry.collapseNoticeShown = false;
    entry.consecutiveAbortedFires =
        aborted ? entry.consecutiveAbortedFires + 1 : 0;
    if (!entry.suspended &&
        entry.consecutiveAbortedFires >= kMaxTimerFiresBeforeSuspend) {
      entry.suspended = true;
      _disarm(entry);
      revision++;
      onMutation?.call({
        if (entry.sessionId case final String owner) owner,
      });
      onNotice(
        '[timer ${entry.name} suspended after $kMaxTimerFiresBeforeSuspend '
        'consecutive failed checks — /timers cancel ${entry.name}, or ask the '
        'agent to fix and re-set it]',
        warning: true,
      );
      return;
    }
    if (entry.once ||
        (entry.maxFires != null && entry.fireCount >= entry.maxFires!)) {
      _disarm(entry);
      _entries.remove(entry.name);
      revision++;
      onMutation?.call({
        if (entry.sessionId case final String owner) owner,
      });
      return;
    }
    _advanceAndArm(entry, now);
  }

  /// Detaches one in-flight fire: its [TimerFireId] stops acking and the
  /// entry returns to [TimerEntryState.idle] without an abort counted (the
  /// operator discarded the fire; the check itself didn't fail). No-op when
  /// [fire] is not the entry's current window. The app calls this — via
  /// [cancelActiveFires]' return value — for enqueued fire prompts it
  /// discards, so no timer is left queued forever (§7).
  void cancelFire(TimerFireId fire) {
    final entry = _entries[fire.name];
    if (entry == null || entry.currentFire != fire) return;
    entry.currentFire = null;
    entry.state = TimerEntryState.idle;
  }

  /// Detaches every in-flight fire (queued or running): their
  /// [TimerFireId]s stop acking, and their id/instruction pairs are returned
  /// so the app can settle the already-enqueued turn prompts (tell the user
  /// the timer is gone) instead of stranding them as queued turns (§7).
  /// Called from [dispose] and by the app when the TUI tears down while a
  /// fire turn is still queued behind an active turn.
  List<(TimerFireId, String)> cancelActiveFires() {
    final cancelled = <(TimerFireId, String)>[];
    for (final entry in _entries.values) {
      final fire = entry.currentFire;
      if (fire == null) continue;
      entry.currentFire = null;
      entry.state = TimerEntryState.idle;
      cancelled.add((fire, entry.instruction));
    }
    return cancelled;
  }

  /// Serializes every entry for the per-session sidecar (§10): counters and
  /// the grid anchor verbatim; queued/running entries save as idle (the
  /// anchor carries the schedule). Plain data out — the caller owns the file.
  List<Map<String, Object?>> exportState() =>
      [for (final e in _entries.values) _exportOf(e)];

  /// Re-arms saved entries verbatim — counters and anchor as saved (§4.2);
  /// a restore never resumes a fire in flight. Entries are restored in the
  /// given order until [kMaxActiveTimers] is reached; the names that did not
  /// fit (over-cap, or colliding with a live runtime timer) are returned.
  /// Malformed records are skipped silently. Suspended entries restore as
  /// suspended (state is truth, §10) and stay disarmed.
  List<String> restoreState(List<Map<String, Object?>> saved) {
    final notRestored = <String>[];
    final restored = <_TimerEntry>[];
    for (final record in saved) {
      final entry = _entryFromRecord(record);
      if (entry == null) continue;
      if (_entries.containsKey(entry.name) ||
          _entries.length >= kMaxActiveTimers) {
        notRestored.add(entry.name);
        continue;
      }
      // Fresh generation: restored entries never collide with an older
      // lifecycle's in-flight fire under the same name.
      entry.generation = _nextRestoreGeneration++;
      _entries[entry.name] = entry;
      restored.add(entry);
      // Anchor as saved; the past-tick rule collapses missed grid points, so
      // the first fire lands on the first FUTURE grid point (§10 step 4).
      if (!entry.suspended) _advanceAndArm(entry, _clock());
    }
    if (restored.isNotEmpty) {
      revision++;
      onMutation?.call({
        for (final entry in restored)
          if (entry.sessionId case final String owner) owner,
      });
    }
    return notRestored;
  }

  /// Cancels every armed timer (§4.3). Called on TUI teardown; afterwards the
  /// service arms nothing new (in-flight acks settle without re-arming).
  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      _disarm(entry);
    }
    cancelActiveFires();
  }

  // -- internals -----------------------------------------------------------

  static Timer _defaultTimerFactory(
          Duration duration, void Function() callback) =>
      Timer(duration, callback);

  void _disarm(_TimerEntry entry) {
    entry.timer?.cancel();
    entry.timer = null;
  }

  /// Arms a one-shot timer for `max(nextAnchor - now, 0)` (§4.4 step 3). A
  /// zero delay is safe: the immediate tick sees a non-idle state (or a future
  /// anchor after the advance below) and collapses.
  void _arm(_TimerEntry entry, DateTime now) {
    _disarm(entry);
    if (_disposed || entry.suspended) return;
    final delay = entry.nextAnchor.isAfter(now)
        ? entry.nextAnchor.difference(now)
        : Duration.zero;
    entry.timer = _timerFactory(delay, () => _onTick(entry));
  }

  /// Advances the anchor to the first grid point after [now], then arms.
  /// Ticks that fell in the past — long check, busy loop, closed laptop —
  /// are skipped (§4.4 step 3). Arms at collapse too (step 3 says re-arm at
  /// fire time, at collapse, and at ackFinished): only the FIRE decision is
  /// state-gated, never the arming.
  void _advanceAndArm(_TimerEntry entry, DateTime now) {
    while (!entry.nextAnchor.isAfter(now)) {
      entry.nextAnchor = entry.nextAnchor.add(entry.interval);
    }
    _arm(entry, now);
  }

  void _onTick(_TimerEntry entry) {
    entry.timer = null;
    final now = _clock();
    switch (entry.state) {
      case TimerEntryState.idle:
        // FIRE (§4.4 step 2): a new in-flight window begins.
        entry.fireCount += 1;
        entry.collapseNoticeShown = false;
        entry.state = TimerEntryState.queued;
        final fire = TimerFireId(
          name: entry.name,
          generation: entry.generation,
          fireNumber: entry.fireCount,
        );
        entry.currentFire = fire;
        onFire(fire);
      case TimerEntryState.queued:
      case TimerEntryState.running:
        // COLLAPSE: at most one fire per timer in flight; the skip notice
        // shows at most once per in-flight window (§4.4 step 2).
        if (!entry.collapseNoticeShown) {
          entry.collapseNoticeShown = true;
          onNotice(
            '[timer ${entry.name} skipped a tick — previous check still in '
            'flight]',
            warning: false,
          );
        }
    }
    _advanceAndArm(entry, now);
  }

  TimerSnapshot _snapshotOf(_TimerEntry entry) => TimerSnapshot(
        name: entry.name,
        interval: entry.interval,
        instruction: entry.instruction,
        fireCount: entry.fireCount,
        once: entry.once,
        maxFires: entry.maxFires,
        suspended: entry.suspended,
        consecutiveAbortedFires: entry.consecutiveAbortedFires,
        state: entry.state,
        nextFireAt: (entry.state == TimerEntryState.idle &&
                !entry.suspended &&
                entry.timer != null)
            ? entry.nextAnchor
            : null,
      );

  /// Sidecar record shape (§10): the schema fields, `interval` as `everyMs`,
  /// the anchor as epoch millis. No `state` field — queued/running save as
  /// idle. Extra runtime-only fields (sessionId) ride along for the store's
  /// grouping; the sidecar schema ignores unknown fields.
  Map<String, Object?> _exportOf(_TimerEntry entry) => <String, Object?>{
        'name': entry.name,
        'everyMs': entry.interval.inMilliseconds,
        'instruction': entry.instruction,
        'once': entry.once,
        'maxFires': entry.maxFires,
        'fireCount': entry.fireCount,
        'consecutiveAbortedFires': entry.consecutiveAbortedFires,
        'suspended': entry.suspended,
        'anchorEpochMs': entry.nextAnchor.millisecondsSinceEpoch,
        'sessionId': entry.sessionId,
      };

  /// Inverse of [_exportOf] for records from [TimerService.restoreState] /
  /// the sidecar store. Returns null on a malformed record (wrong types,
  /// non-positive interval, missing fields) — restore skips those.
  static _TimerEntry? _entryFromRecord(Map<String, Object?> record) {
    final name = record['name'];
    final everyMs = record['everyMs'];
    final instruction = record['instruction'];
    final once = record['once'];
    final maxFires = record['maxFires'];
    final fireCount = record['fireCount'];
    final consecutiveAbortedFires = record['consecutiveAbortedFires'];
    final suspended = record['suspended'];
    final anchorEpochMs = record['anchorEpochMs'];
    if (name is! String || name.isEmpty) return null;
    if (everyMs is! int || everyMs <= 0) return null;
    if (instruction is! String) return null;
    if (once is! bool) return null;
    if (maxFires != null && (maxFires is! int || maxFires < 1)) return null;
    if (fireCount is! int || fireCount < 0) return null;
    if (consecutiveAbortedFires is! int || consecutiveAbortedFires < 0)
      return null;
    if (suspended is! bool) return null;
    if (anchorEpochMs is! int) return null;
    return _TimerEntry(
      name: name,
      sessionId:
          record['sessionId'] is String ? record['sessionId'] as String : null,
      interval: Duration(milliseconds: everyMs),
      instruction: instruction,
      once: once,
      maxFires: maxFires as int?,
      nextAnchor: DateTime.fromMillisecondsSinceEpoch(anchorEpochMs),
    )
      ..fireCount = fireCount
      ..consecutiveAbortedFires = consecutiveAbortedFires
      ..suspended = suspended;
  }
}
