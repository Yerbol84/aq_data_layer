import 'dart:async';
import 'dart:math';

import 'package:aq_schema/aq_schema.dart';

/// In-memory vector storage with brute-force cosine similarity search.
///
/// - Zero external dependencies.
/// - O(n·d) search — suitable for development, tests, and small corpora
///   (< ~10 000 vectors with d ≤ 1536).
/// - For production, replace with [QdrantVectorStorage] or [PgVectorStorage].
final class InMemoryVectorStorage implements VectorStorage {
  // collection → { id → VectorEntry }
  final _store = <String, Map<String, VectorEntry>>{};
  final _sizes = <String, int>{}; // expected vector size per collection

  // ── Collections ────────────────────────────────────────────────────────────

  @override
  Future<void> ensureCollection(
    String collection, {
    required int vectorSize,
    String distance = 'cosine',
  }) async {
    _store.putIfAbsent(collection, () => {});
    _sizes[collection] = vectorSize;
  }

  @override
  Future<void> deleteCollection(String collection) async {
    _store.remove(collection);
    _sizes.remove(collection);
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> upsert(String collection, VectorEntry entry) async {
    _store.putIfAbsent(collection, () => {}); // auto-create
    _validateDimension(collection, entry.vector);
    _store[collection]![entry.id] = entry;
  }

  @override
  Future<void> upsertAll(String collection, List<VectorEntry> entries) async {
    _store.putIfAbsent(collection, () => {});
    for (final e in entries) {
      _validateDimension(collection, e.vector);
      _store[collection]![e.id] = e;
    }
  }

  @override
  Future<void> delete(String collection, String id) async {
    _store[collection]?.remove(id);
  }

  @override
  Future<void> deleteWhere(String collection, VaultQuery filter) async {
    final col = _store[collection];
    if (col == null) return;
    final toRemove = col.values
        .where((e) => filter.applyFiltersOnly([e.payload]).isNotEmpty)
        .map((e) => e.id)
        .toList();
    for (final id in toRemove) {
      col.remove(id);
    }
  }

  // ── Search ─────────────────────────────────────────────────────────────────

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
    final col = _store[collection];
    if (col == null || col.isEmpty) return [];

    var candidates = col.values.toList();

    // Mandatory tenant isolation
    candidates = candidates
        .where((e) => e.payload['tenantId'] == tenantId)
        .toList();

    // Apply additional payload filter
    if (filter != null && filter.filters.isNotEmpty) {
      candidates = candidates
          .where((e) => filter.applyFiltersOnly([e.payload]).isNotEmpty)
          .toList();
    }

    // Compute scores
    final scored = candidates.map((e) {
      final denseScore = _cosineSimilarity(queryVector, e.vector);

      double sparseScore = 0.0;
      if (sparseQuery != null && sparseQuery.isNotEmpty) {
        final text = (e.payload['text'] as String? ?? '').toLowerCase();
        final terms = sparseQuery.toLowerCase().split(RegExp(r'\s+'));
        final hits = terms.where((t) => t.isNotEmpty && text.contains(t)).length;
        sparseScore = terms.isEmpty ? 0.0 : hits / terms.length;
      }

      final score = sparseQuery != null
          ? alpha * denseScore + (1.0 - alpha) * sparseScore
          : denseScore;

      return VectorSearchResult(id: e.id, score: score, payload: e.payload);
    }).toList();

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.where((r) => r.score >= scoreThreshold).take(limit).toList();
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  @override
  Future<VectorEntry?> getById(String collection, String id) async =>
      _store[collection]?[id];

  @override
  Future<List<VectorEntry>> getAll(
    String collection, {
    VaultQuery? filter,
  }) async {
    final col = _store[collection];
    if (col == null) return [];
    final all = col.values.toList();
    if (filter == null || filter.filters.isEmpty) return all;
    return all
        .where((e) => filter.applyFiltersOnly([e.payload]).isNotEmpty)
        .toList();
  }

  @override
  Future<int> count(String collection, {VaultQuery? filter}) async {
    final all = await getAll(collection, filter: filter);
    return all.length;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    _store.clear();
    _sizes.clear();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  /// Cosine similarity in [–1, 1]; clamped to [0, 1] for convenience.
  double _cosineSimilarity(List<double> a, List<double> b) {
    final len = min(a.length, b.length);
    if (len == 0) return 0;

    double dot = 0, normA = 0, normB = 0;
    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return (dot / (sqrt(normA) * sqrt(normB))).clamp(0.0, 1.0);
  }

  void _validateDimension(String collection, List<double> vector) {
    final expected = _sizes[collection];
    if (expected != null && vector.length != expected) {
      throw ArgumentError(
        'Vector dimension mismatch for collection "$collection": '
        'expected $expected, got ${vector.length}',
      );
    }
  }
}
