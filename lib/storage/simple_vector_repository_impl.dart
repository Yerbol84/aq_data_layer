import 'package:aq_schema/aq_schema.dart';

import '../repositories/vector_repository.dart';

/// Simple VectorStorage wrapper implementing VectorRepository.
/// Used by KnowledgeVault for standalone vector collections.
final class SimpleVectorRepositoryImpl implements VectorRepository {
  final VectorStorage _storage;
  final String _collection;

  SimpleVectorRepositoryImpl({
    required VectorStorage storage,
    required String collection,
    String tenantId = 'system', // kept for API compatibility, passed by caller
  })  : _storage = storage,
        _collection = collection;

  @override
  Future<void> upsert(VectorEntry entry) =>
      _storage.upsert(_collection, entry);

  @override
  Future<void> upsertAll(List<VectorEntry> entries) =>
      _storage.upsertAll(_collection, entries);

  @override
  Future<void> delete(String id) => _storage.delete(_collection, id);

  @override
  Future<void> deleteWhere(VaultQuery filter) =>
      _storage.deleteWhere(_collection, filter);

  @override
  Future<List<VectorSearchResult>> search(
    List<double> queryVector, {
    required String tenantId,
    int limit = 10,
    double scoreThreshold = 0.0,
    VaultQuery? filter,
    String? sparseQuery,
    double alpha = 1.0,
  }) =>
      _storage.search(
        _collection,
        queryVector,
        tenantId: tenantId,
        limit: limit,
        scoreThreshold: scoreThreshold,
        filter: filter,
        sparseQuery: sparseQuery,
        alpha: alpha,
      );

  @override
  Future<VectorEntry?> getById(String id) => _storage.getById(_collection, id);

  @override
  Future<List<VectorEntry>> getAll({VaultQuery? filter}) =>
      _storage.getAll(_collection, filter: filter);

  @override
  Future<PageResult<VectorEntry>> getPage(VaultQuery query) async {
    final all = await getAll();
    final filtered = query.applyFiltersOnly(
      all.map((e) => e.toMap()).toList(),
    );
    final total = filtered.length;
    final paged = query.apply(filtered);
    return PageResult(
      items: paged.map(VectorEntry.fromMap).toList(),
      total: total,
      offset: query.offset ?? 0,
      limit: query.limit ?? total,
    );
  }

  @override
  Future<int> count({VaultQuery? filter}) =>
      _storage.count(_collection, filter: filter);
}
