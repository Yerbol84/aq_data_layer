import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';

import '../repositories/vector_repository.dart';

/// Default implementation of [VectorRepository] backed by [VectorStorage].
@internal
final class VectorRepositoryImpl implements VectorRepository {
  final VectorStorage _storage;
  final String _collection;

  VectorRepositoryImpl({
    required VectorStorage storage,
    required String collection,
  })  : _storage = storage,
        _collection = collection;

  @override
  Future<void> upsert(VectorEntry entry) => _storage.upsert(_collection, entry);

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
    int limit = 10,
    double scoreThreshold = 0.0,
    VaultQuery? filter,
  }) =>
      _storage.search(
        _collection,
        queryVector,
        limit: limit,
        scoreThreshold: scoreThreshold,
        filter: filter,
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
    final paged = query.apply(filtered
        .map((m) => VectorEntry.fromMap(m))
        .toList()
        .map((e) => e.toMap())
        .toList());
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
