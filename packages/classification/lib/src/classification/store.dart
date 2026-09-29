/// Storage implementations publish complete JSON atomically. The exclusive
/// writer scope serializes manifest updates across processes as well as tasks.
abstract interface class ClassificationStore {
  Future<T> withWriter<T>(Future<T> Function() work);
  Future<Map<String, dynamic>?> readManifest();
  Future<Map<String, dynamic>?> readRecord(String id);
  Future<void> writeRecord(String id, Map<String, Object?> record);
  Future<void> writeManifest(Map<String, Object?> manifest);
}

/// Stores with transactional checkpoints can update one reference without
/// rewriting the entire manifest. The classifier remains storage-independent.
abstract interface class CheckpointStore implements ClassificationStore {
  Future<void> publish(String key, String id, Map<String, Object?> record);
  Future<void> retainTasks(Set<String> keys);
}
