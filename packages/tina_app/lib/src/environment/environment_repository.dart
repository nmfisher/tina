class EnvironmentSnapshot {
  final bool recordPresent;
  final String? staleReason;
  final List<int>? recordBytes;
  EnvironmentSnapshot({
    required this.recordPresent,
    this.staleReason,
    List<int>? recordBytes,
  }) : recordBytes = recordBytes == null
           ? null
           : List.unmodifiable(recordBytes);
}

abstract interface class EnvironmentRepository {
  EnvironmentSnapshot inspect({bool captureRecord = false});

  /// Verify presence on first load or changed bytes on re-verification.
  bool advanced(EnvironmentSnapshot before);
  void record();
}
