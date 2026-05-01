import 'package:aq_schema/aq_schema.dart';
import 'remote_vault_storage.dart';

/// Client-side VectorStorage that delegates to the server via RPC.
/// Mirrors PgVectorStorage/InMemoryVectorStorage on the server.
final class RemoteVectorStorage implements VectorStorage {
  final RemoteVaultStorage _remote;

  RemoteVectorStorage({required RemoteVaultStorage remote})
      : _remote = remote;

  @override
  Future<void> ensureCollection(
    String collection, {
    required int vectorSize,
    String distance = 'cosine',
  }) async {
    await _remote.rpc('__vectors', 'vectorEnsure', {
      'storeId': 'pgvector-main',
      'collection': collection,
      'vectorDim': vectorSize,
    });
  }

  @override
  Future<void> deleteCollection(String collection) async {}

  @override
  Future<void> upsert(String collection, VectorEntry entry) =>
      upsertAll(collection, [entry]);

  @override
  Future<void> upsertAll(String collection, List<VectorEntry> entries) async {
    await _remote.rpc('__vectors', 'vectorUpsert', {
      'storeId': 'pgvector-main',
      'collection': collection,
      'entries': entries.map((e) => e.toMap()).toList(),
    });
  }

  @override
  Future<void> delete(String collection, String id) async {
    await _remote.rpc('__vectors', 'vectorDelete', {
      'storeId': 'pgvector-main',
      'collection': collection,
      'artifactId': id,
    });
  }

  @override
  Future<void> deleteWhere(String collection, VaultQuery filter) async {
    // Extract artifactId from filter for server-side delete
    final artifactFilter = filter.filters
        .where((f) => f.field == 'artifactId' && f.operator == VaultOperator.equals)
        .firstOrNull;
    if (artifactFilter != null) {
      await _remote.rpc('__vectors', 'vectorDelete', {
        'storeId': 'pgvector-main',
        'collection': collection,
        'artifactId': artifactFilter.value as String,
      });
    }
  }

  @override
  Future<List<VectorSearchResult>> search(
    String collection,
    List<double> queryVector, {
    required String tenantId,
    int limit = 10,
    double scoreThreshold = 0.0,
    VaultQuery? filter,
    String metric = 'cosine',
    String? sparseQuery,
    double alpha = 1.0,
  }) async {
    final result = await _remote.rpc('__vectors', 'vectorSearch', {
      'storeId': 'pgvector-main',
      'collection': collection,
      'vector': queryVector,
      'limit': limit,
      'scoreThreshold': scoreThreshold,
      if (sparseQuery != null) 'sparseQuery': sparseQuery,
      'alpha': alpha,
      // Serialize equality filters as key-value map for server-side filtering
      if (filter != null && filter.filters.isNotEmpty)
        'filter': {
          for (final f in filter.filters)
            if (f.operator == VaultOperator.equals) f.field: f.value?.toString(),
        },
    });
    if (result == null) return [];
    return (result as List).cast<Map<String, dynamic>>().map((m) {
      return VectorSearchResult(
        id: m['id'] as String,
        score: (m['score'] as num).toDouble(),
        payload: m['payload'] as Map<String, dynamic>,
      );
    }).toList();
  }

  @override
  Future<VectorEntry?> getById(String collection, String id) async => null;

  @override
  Future<List<VectorEntry>> getAll(String collection,
          {VaultQuery? filter}) async =>
      [];

  @override
  Future<int> count(String collection, {VaultQuery? filter}) async => 0;

  @override
  Future<void> dispose() async {}
}
