/// Base repository interface for CRUD operations
abstract class Repository<T> {
  /// Save entity
  Future<T> save(T entity);

  /// Save multiple entities
  Future<List<T>> saveAll(List<T> entities);

  /// Find entity by ID
  Future<T?> findById(String id);

  /// Find all entities with optional filtering and pagination
  Future<List<T>> findAll({
    int? limit,
    int? offset,
    Map<String, dynamic>? where,
  });

  /// Count entities with optional filtering
  Future<int> count({Map<String, dynamic>? where});

  /// Delete entity by ID
  Future<void> delete(String id);

  /// Delete multiple entities by IDs
  Future<void> deleteAll(List<String> ids);

  /// Check if entity exists
  Future<bool> exists(String id);
}
