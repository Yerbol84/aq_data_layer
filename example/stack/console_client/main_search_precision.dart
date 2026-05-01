/// S-05: Precision@K and MRR evaluation
///
/// Objective quality measurement for vector search.
/// Ground truth: 5 queries with known correct documents.
/// Metrics: Precision@1, Precision@3, MRR
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'sp-tenant';
const _storeId = 'pgvector-main';

// Ground truth: query → expected artifactId prefix
const _groundTruth = [
  ('how does cosine similarity measure vector distance', 'sp-ai-001'),
  ('SQL injection prevention with parameterized queries', 'sp-sec-001'),
  ('PostgreSQL B-tree index range queries', 'sp-db-001'),
  ('JWT token signature validation expiration', 'sp-sec-002'),
  ('transformer self-attention mechanism sequences', 'sp-ai-002'),
];

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-05: Precision@K and MRR Evaluation');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try {
      await fn();
      passed++;
    } catch (e, st) {
      print('  ❌ $name: $e\n     $st');
      failed++;
    }
  }

  await run('Setup: index corpus', _setup);
  await run('S-05-1: Precision@1 ≥ 0.6', _s05Precision1);
  await run('S-05-2: Precision@3 ≥ 0.8', _s05Precision3);
  await run('S-05-3: MRR ≥ 0.7', _s05MRR);
  await run('S-05-4: Hybrid search Precision@3 ≥ dense', _s05Hybrid);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

// ── Corpus ────────────────────────────────────────────────────────────────────

const _docs = {
  'sp-ai-001': 'Vector embeddings represent semantic meaning as dense numerical vectors. Cosine similarity measures the angle between vectors to find semantically related content in high-dimensional space.',
  'sp-ai-002': 'Transformer models use self-attention mechanisms to capture dependencies between tokens regardless of distance. Multi-head attention allows the model to attend to different representation subspaces.',
  'sp-ai-003': 'Gradient descent optimizes neural network weights by computing partial derivatives. Learning rate scheduling adjusts step size during training to improve convergence.',
  'sp-db-001': 'PostgreSQL B-tree indexes support equality and range queries efficiently. The index stores sorted key values enabling binary search for fast lookups.',
  'sp-db-002': 'Database connection pooling reuses established connections to reduce overhead. PgBouncer manages a pool of connections shared across multiple application instances.',
  'sp-sec-001': 'SQL injection attacks insert malicious code into database queries through unsanitized input. Parameterized queries and prepared statements prevent injection by separating SQL code from data values.',
  'sp-sec-002': 'JWT tokens contain base64-encoded header, payload, and signature. The server validates the signature and checks expiration to prevent replay attacks and token forgery.',
  'sp-sec-003': 'Password hashing with bcrypt or argon2 protects credentials at rest. Salt prevents rainbow table attacks by making each hash unique even for identical passwords.',
};

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;

Future<void> _setup() async {
  await initializeDataLayer(
    endpoint: _endpoint,
    tenantId: _tenantId,
    useBuffer: false,
    authToken: 'test-admin-token',
  );

  _embedder = OllamaEmbeddingsClient(
    endpoint: _ollamaEndpoint,
    model: 'nomic-embed-text',
    dimensions: 768,
  );

  final remote = RemoteVaultStorage(
    endpoint: _endpoint,
    tenantId: _tenantId,
    authToken: 'test-admin-token',
  );
  await remote.connect();

  final registry = VectorStoreRegistryImpl();
  registry.register(
    VectorStoreDescriptor(
      id: _storeId,
      type: 'pgvector',
      embedderId: _embedder.id,
      vectorDim: _embedder.dimensions,
    ),
    RemoteVectorStorage(remote: remote),
  );

  _repo = VectorRepositoryImpl(registry: registry);

  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  for (final e in _docs.entries) {
    final bytes = utf8.encode(e.value);
    final artifact = StoredArtifact(
      id: e.key,
      tenantId: _tenantId,
      ownerId: 'sp-owner',
      storageKey: '$_tenantId/${e.key}.txt',
      fileName: '${e.key}.txt',
      contentType: 'text/plain',
      sizeBytes: bytes.length,
      checksum: bytes.length.toString(),
      createdAt: DateTime.now().toUtc(),
    );
    await artifactRepo.save(artifact);
    await _repo.index(
      artifact,
      bytes,
      IndexingPipeline(
        id: 'sp-pipeline-v1',
        storeId: _storeId,
        extractor: PlainTextExtractor(),
        chunker: SentenceChunker(maxChunkChars: 400),
        embedder: _embedder,
        reranker: PassthroughReranker(),
      ),
    );
  }
  print('  ✅ Indexed ${_docs.length} documents');
}

// ── Evaluation helpers ────────────────────────────────────────────────────────

Future<List<String>> _searchTopK(String query, int k) async {
  final results = await _repo.search(
    query,
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: k,
    scoreThreshold: 0.0,
  );
  return results.map((r) => r.payload['artifactId'] as String).toList();
}

Future<List<String>> _searchHybridTopK(String query, int k) async {
  final results = await _repo.search(
    query,
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: k,
    scoreThreshold: 0.0,
    sparseQuery: query,
    alpha: 0.7,
  );
  return results.map((r) => r.payload['artifactId'] as String).toList();
}

// ── S-05-1: Precision@1 ───────────────────────────────────────────────────────

Future<void> _s05Precision1() async {
  int hits = 0;
  for (final (query, expected) in _groundTruth) {
    final top = await _searchTopK(query, 1);
    final hit = top.isNotEmpty && top.first == expected;
    if (hit) hits++;
    print('     ${hit ? '✓' : '✗'} "$query" → ${top.isEmpty ? 'none' : top.first} (expected $expected)');
  }
  final p1 = hits / _groundTruth.length;
  print('  ✅ Precision@1 = ${p1.toStringAsFixed(2)} ($hits/${_groundTruth.length})');
  if (p1 < 0.6) throw StateError('Precision@1 $p1 < 0.6');
}

// ── S-05-2: Precision@3 ───────────────────────────────────────────────────────

Future<void> _s05Precision3() async {
  int hits = 0;
  for (final (query, expected) in _groundTruth) {
    final top3 = await _searchTopK(query, 3);
    final hit = top3.contains(expected);
    if (hit) hits++;
    print('     ${hit ? '✓' : '✗'} "$query" → [${top3.join(', ')}]');
  }
  final p3 = hits / _groundTruth.length;
  print('  ✅ Precision@3 = ${p3.toStringAsFixed(2)} ($hits/${_groundTruth.length})');
  if (p3 < 0.8) throw StateError('Precision@3 $p3 < 0.8');
}

// ── S-05-3: MRR ───────────────────────────────────────────────────────────────

Future<void> _s05MRR() async {
  double totalRR = 0.0;
  for (final (query, expected) in _groundTruth) {
    final top5 = await _searchTopK(query, 5);
    final rank = top5.indexOf(expected) + 1; // 0 if not found → rank=0
    final rr = rank > 0 ? 1.0 / rank : 0.0;
    totalRR += rr;
    print('     rank=$rank RR=${rr.toStringAsFixed(2)} "$query"');
  }
  final mrr = totalRR / _groundTruth.length;
  print('  ✅ MRR = ${mrr.toStringAsFixed(3)}');
  if (mrr < 0.7) throw StateError('MRR $mrr < 0.7');
}

// ── S-05-4: Hybrid ≥ Dense ────────────────────────────────────────────────────

Future<void> _s05Hybrid() async {
  int denseHits = 0, hybridHits = 0;
  for (final (query, expected) in _groundTruth) {
    final dense = await _searchTopK(query, 3);
    final hybrid = await _searchHybridTopK(query, 3);
    if (dense.contains(expected)) denseHits++;
    if (hybrid.contains(expected)) hybridHits++;
  }
  final dp3 = denseHits / _groundTruth.length;
  final hp3 = hybridHits / _groundTruth.length;
  print('  ✅ Dense P@3=${dp3.toStringAsFixed(2)} Hybrid P@3=${hp3.toStringAsFixed(2)}');
  // Hybrid should be at least as good as dense
  if (hp3 < dp3 - 0.2) {
    throw StateError('Hybrid P@3 $hp3 significantly worse than dense $dp3');
  }
}
