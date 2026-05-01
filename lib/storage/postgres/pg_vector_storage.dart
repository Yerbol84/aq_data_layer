import 'dart:convert';
import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

/// [VectorStorage] backed by PostgreSQL with pgvector extension.
///
/// Table schema per collection:
///   id TEXT PK, tenant_id TEXT, vector vector(N), payload JSONB,
///   text_search TSVECTOR (generated from payload->>'text')
///
/// Supports:
/// - Dense search: cosine distance via <=> operator + ivfflat index
/// - Sparse search: BM25 via ts_rank + GIN index on tsvector
/// - Hybrid: alpha * dense + (1-alpha) * sparse
final class PgVectorStorage implements VectorStorage {
  final Pool<Object?> _pool;

  PgVectorStorage({required Pool<Object?> pool}) : _pool = pool;

  // ── Collections ────────────────────────────────────────────────────────────

  @override
  Future<void> ensureCollection(
    String collection, {
    required int vectorSize,
    String distance = 'cosine',
  }) async {
    final safe = _safeName(collection);
    final ops = distance == 'cosine' ? 'vector_cosine_ops' : 'vector_l2_ops';
    await _pool.execute('CREATE EXTENSION IF NOT EXISTS vector');
    await _pool.execute('''
      CREATE TABLE IF NOT EXISTS $safe (
        id TEXT PRIMARY KEY,
        tenant_id TEXT NOT NULL,
        vector vector($vectorSize),
        payload JSONB NOT NULL DEFAULT '{}',
        text_search TSVECTOR GENERATED ALWAYS AS
          (to_tsvector('english', coalesce(payload->>'text', ''))) STORED
      )
    ''');
    await _pool.execute('''
      CREATE INDEX IF NOT EXISTS ${safe}_vector_idx
        ON $safe USING ivfflat (vector $ops) WITH (lists = 10)
    ''');
    await _pool.execute(
      'CREATE INDEX IF NOT EXISTS ${safe}_tenant_idx ON $safe (tenant_id)',
    );
    await _pool.execute(
      'CREATE INDEX IF NOT EXISTS ${safe}_text_idx ON $safe USING gin(text_search)',
    );
  }

  @override
  Future<void> deleteCollection(String collection) async {
    await _pool.execute('DROP TABLE IF EXISTS ${_safeName(collection)}');
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> upsert(String collection, VectorEntry entry) =>
      upsertAll(collection, [entry]);

  @override
  Future<void> upsertAll(String collection, List<VectorEntry> entries) async {
    if (entries.isEmpty) return;
    final safe = _safeName(collection);
    await _pool.runTx((conn) async {
      for (final e in entries) {
        final tenantId = e.payload['tenantId'] as String? ?? 'system';
        final vec = '[${e.vector.join(',')}]';
        await conn.execute(
          Sql.named('''
            INSERT INTO $safe (id, tenant_id, vector, payload)
            VALUES (@id, @tenantId, @vec::vector, @payload::jsonb)
            ON CONFLICT (id) DO UPDATE
              SET tenant_id = EXCLUDED.tenant_id,
                  vector = EXCLUDED.vector,
                  payload = EXCLUDED.payload
          '''),
          parameters: {
            'id': e.id,
            'tenantId': tenantId,
            'vec': vec,
            'payload': jsonEncode(e.payload),
          },
        );
      }
    });
  }

  @override
  Future<void> delete(String collection, String id) async {
    await _pool.execute(
      Sql.named('DELETE FROM ${_safeName(collection)} WHERE id = @id'),
      parameters: {'id': id},
    );
  }

  @override
  Future<void> deleteWhere(String collection, VaultQuery filter) async {
    final safe = _safeName(collection);
    final conditions = <String>[];
    final params = <String, Object?>{};
    for (final f in filter.filters) {
      if (f.operator == VaultOperator.equals) {
        final key = 'p_${f.field}';
        conditions.add("payload->>'${f.field}' = @$key");
        params[key] = f.value?.toString();
      }
    }
    if (conditions.isEmpty) return;
    await _pool.execute(
      Sql.named('DELETE FROM $safe WHERE ${conditions.join(' AND ')}'),
      parameters: params,
    );
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
    final safe = _safeName(collection);
    final vec = '[${queryVector.join(',')}]';

    final extraConditions = <String>[];
    final params = <String, Object?>{
      'tenantId': tenantId,
      'vec': vec,
      'limit': limit,
    };

    if (filter != null) {
      for (final f in filter.filters) {
        if (f.operator == VaultOperator.equals) {
          final key = 'f_${f.field}';
          extraConditions.add("payload->>'${f.field}' = @$key");
          params[key] = f.value?.toString();
        }
      }
    }

    final baseWhere = [
      'tenant_id = @tenantId',
      ...extraConditions,
    ].join(' AND ');

    final String scoreExpr;
    if (sparseQuery != null && sparseQuery.isNotEmpty && alpha < 1.0) {
      // Hybrid: alpha * dense + (1-alpha) * sparse
      params['sparseQuery'] = sparseQuery;
      params['alpha'] = alpha;
      scoreExpr = '''
        @alpha::float * (1 - (vector <=> @vec::vector))
        + (1 - @alpha::float) * ts_rank(text_search, plainto_tsquery('english', @sparseQuery))
      ''';
    } else {
      // Pure dense
      scoreExpr = '1 - (vector <=> @vec::vector)';
    }

    params['threshold'] = scoreThreshold;

    final rows = await _pool.execute(
      Sql.named('''
        SELECT id, payload, ($scoreExpr) AS score
        FROM $safe
        WHERE $baseWhere
          AND ($scoreExpr) >= @threshold
        ORDER BY ($scoreExpr) DESC
        LIMIT @limit
      '''),
      parameters: params,
    );

    return rows.map((row) {
      final payload = _decodeJsonb(row[1]);
      return VectorSearchResult(
        id: row[0] as String,
        score: (row[2] as num).toDouble().clamp(0.0, 1.0),
        payload: payload,
      );
    }).toList();
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  @override
  Future<VectorEntry?> getById(String collection, String id) async {
    final rows = await _pool.execute(
      Sql.named(
          'SELECT id, vector, payload FROM ${_safeName(collection)} WHERE id = @id'),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _rowToEntry(rows.first);
  }

  @override
  Future<List<VectorEntry>> getAll(String collection,
      {VaultQuery? filter}) async {
    final safe = _safeName(collection);
    final rows =
        await _pool.execute('SELECT id, vector, payload FROM $safe');
    var entries = rows.map(_rowToEntry).toList();
    if (filter != null && filter.filters.isNotEmpty) {
      entries = entries
          .where((e) => filter.applyFiltersOnly([e.payload]).isNotEmpty)
          .toList();
    }
    return entries;
  }

  @override
  Future<int> count(String collection, {VaultQuery? filter}) async {
    final rows = await _pool
        .execute('SELECT COUNT(*) FROM ${_safeName(collection)}');
    return (rows.first[0] as int?) ?? 0;
  }

  @override
  Future<void> dispose() async {}

  // ── Private ────────────────────────────────────────────────────────────────

  String _safeName(String collection) =>
      collection.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

  VectorEntry _rowToEntry(ResultRow row) {
    final vecStr = row[1] as String;
    final vector = vecStr
        .replaceAll('[', '')
        .replaceAll(']', '')
        .split(',')
        .map(double.parse)
        .toList();
    final payload = _decodeJsonb(row[2]);
    return VectorEntry(id: row[0] as String, vector: vector, payload: payload);
  }

  Map<String, dynamic> _decodeJsonb(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    return {};
  }
}
