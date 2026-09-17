/// Persisted settings for structured judgments, separate from chat providers.
class TypeSafeSettings {
  final String? apiKey;
  final String? model;
  const TypeSafeSettings({this.apiKey, this.model});

  factory TypeSafeSettings.fromMap(Map<String, dynamic> map) =>
      TypeSafeSettings(
        apiKey: map['api_key'] as String?,
        model: map['model'] as String?,
      );

  bool get isEmpty => apiKey == null && model == null;
  Map<String, Object?> toMap() => {
    if (apiKey != null) 'api_key': apiKey,
    if (model != null) 'model': model,
  };

  @override
  bool operator ==(Object other) =>
      other is TypeSafeSettings &&
      apiKey == other.apiKey &&
      model == other.model;
  @override
  int get hashCode => Object.hash(apiKey, model);
}
