/// Storage implementations publish complete JSON atomically. The exclusive
/// writer scope serializes manifest updates across processes as well as tasks.
abstract interface class ClassificationStore {
  Future<T> withWriter<T>(Future<T> Function() work);
  Future<Map<String, dynamic>?> readManifest();
  Future<Map<String, dynamic>?> readRecord(String id);
  Future<void> writeRecord(String id, Map<String, Object?> record);
  Future<void> writeManifest(Map<String, Object?> manifest);
}
