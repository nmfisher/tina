/// Plain persisted theme values. Console mapping belongs to the frontend.
class ThemeOverrides {
  final Map<String, dynamic> values;
  ThemeOverrides(Map<String, dynamic> values) : values = _freezeMap(values);

  Map<String, dynamic> toMap() => _copyMap(values);
}

Map<String, dynamic> _freezeMap(Map<String, dynamic> values) =>
    Map.unmodifiable({
      for (final entry in values.entries) entry.key: _freeze(entry.value),
    });
Object? _freeze(Object? value) => switch (value) {
  Map value => _freezeMap(value.cast<String, dynamic>()),
  List value => List.unmodifiable(value.map(_freeze)),
  _ => value,
};
Map<String, dynamic> _copyMap(Map<String, dynamic> values) => {
  for (final entry in values.entries) entry.key: _copy(entry.value),
};
Object? _copy(Object? value) => switch (value) {
  Map value => _copyMap(value.cast<String, dynamic>()),
  List value => value.map(_copy).toList(),
  _ => value,
};
