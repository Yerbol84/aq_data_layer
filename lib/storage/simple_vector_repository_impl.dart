import 'package:aq_schema/aq_schema.dart';

/// Thin wrapper over [VectorStorage] implementing [IVectorRepository].
///
/// Binds a single [collection] to a [VectorStorage] backend.
/// All operations delegate to the underlying storage.
final class SimpleVectorRepositoryImpl implements IVectorRepository {
  final VectorStorage _storage;
  final String _collection;
  final int _vectorSize;

  SimpleVectorRepositoryImpl({
    required VectorStorage storage,
    required String collection,
    int vectorSize = 768,
  })  : _storage = storage,
        _collection = collection,
        _vectorSize = vectorSize;

  Future<void> _ensureCollection() =>
      _storage.ensureCollection(_collection, vectorSize: _vectorSize);

  @override
  Future<void> upsert(VectorEntry vectorEntry) async {
    await _ensureCollection();
    await _storage.upsert(_collection, vectorEntry);
  }

  @override
  Future<void> upsertAll(List<VectorEntry> vectorEntries) async {
    await _ensureCollection();
    await _storage.upsertAll(_collection, vectorEntries);
  }

  @override
  Future<void> delete(String id) => _storage.delete(_collection, id);

  @override
  Future<void> deleteWhere(VaultQuery vaultQuery) =>
      _storage.deleteWhere(_collection, vaultQuery);

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
  Future<PageResult<VectorEntry>> getPage(VaultQuery vaultQuery) async {
    final all = await _storage.getAll(_collection);
    final offset = vaultQuery.offset ?? 0;
    final limit = vaultQuery.limit ?? all.length;
    return PageResult(
      items: all.skip(offset).take(limit).toList(),
      total: all.length,
      offset: offset,
      limit: limit,
    );
  }

  @override
  Future<int> count({VaultQuery? filter}) =>
      _storage.count(_collection, filter: filter);
}
