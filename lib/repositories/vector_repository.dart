import 'package:aq_schema/aq_schema.dart';

/// Repository for vector embeddings with ANN search.
///
/// Use for: RAG pipelines, semantic search, document similarity.
///
/// ## Typical workflow
///
/// ```dart
/// // 1. Index a document
/// final embedding = await llm.embed(chunkText);
/// await vectors.upsert(VectorEntry(
///   id: 'doc-abc__chunk-0',
///   vector: embedding,
///   payload: {'docId': 'doc-abc', 'chunkIndex': 0, 'text': chunkText},
/// ));
///
/// // 2. Search
/// final queryVec = await llm.embed('What is the refund policy?');
/// final results  = await vectors.search(queryVec, limit: 5);
/// ```
///
/// ## Multi-tenancy
///
/// The [KnowledgeVault] creates the collection name as
/// `{tenantId}__documents_vectors`; you never need to prefix manually.
abstract interface class VectorRepository {
  // ── Write ──────────────────────────────────────────────────────────────────

  Future<void> upsert(VectorEntry entry);
  Future<void> upsertAll(List<VectorEntry> entries);
  Future<void> delete(String id);

  /// Delete all entries whose payload matches [filter].
  /// Example: delete all chunks for a document:
  ///   `deleteWhere(VaultQuery().where('docId', VaultOperator.equals, id))`
  Future<void> deleteWhere(VaultQuery filter);

  // ── Search ─────────────────────────────────────────────────────────────────

  Future<List<VectorSearchResult>> search(
    List<double> queryVector, {
    required String tenantId,
    int limit = 10,
    double scoreThreshold = 0.0,
    VaultQuery? filter,
    String? sparseQuery,
    double alpha = 1.0,
  });

  // ── Read ───────────────────────────────────────────────────────────────────

  Future<VectorEntry?> getById(String id);
  Future<List<VectorEntry>> getAll({VaultQuery? filter});
  Future<PageResult<VectorEntry>> getPage(VaultQuery query);
  Future<int> count({VaultQuery? filter});
}
