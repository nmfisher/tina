/// The session's counters: depth, children in flight, tokens spent.
///
/// Plain mutable fields, like the session's turn list. The store turns
/// them into JSON on the registry marker row and back; nothing else in
/// the workspace defines that shape twice.
final class SessionDetails {
  SessionDetails({
    this.depth = 0,
    this.childrenInFlight = 0,
    this.tokensSpent = 0,
  });

  /// How deep this session sits: 0 for a session nobody spawned, 1 for
  /// a child of one, and so on. The spawn policy that reads it lives
  /// elsewhere — the session only records the fact.
  int depth;

  /// How many child sessions are running right now. Whoever spawns
  /// increments before the child runs and decrements when it settles,
  /// so the number reads true at every moment in between.
  int childrenInFlight;

  /// Tokens this session's children are known to have spent. Reported
  /// usage, added as it arrives; an additive counter, never recomputed.
  int tokensSpent;

  /// The JSON object a store row carries. Keys are stable wire names.
  Map<String, Object?> toJson() => {
        'depth': depth,
        'children_in_flight': childrenInFlight,
        'tokens_spent': tokensSpent,
      };

  /// The details a stored payload named. Absent keys read as zero, so
  /// rows written before details existed resume cleanly.
  factory SessionDetails.fromJson(Map<String, Object?> j) => SessionDetails(
        depth: (j['depth'] as num?)?.toInt() ?? 0,
        childrenInFlight: (j['children_in_flight'] as num?)?.toInt() ?? 0,
        tokensSpent: (j['tokens_spent'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'SessionDetails(depth $depth, '
      '${childrenInFlight} in flight, $tokensSpent tokens)';
}
