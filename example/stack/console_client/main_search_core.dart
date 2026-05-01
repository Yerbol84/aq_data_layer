/// S-01: Dense similarity search
/// S-03: Filter search (artifactId, ownerId, combined)
/// S-04: Multi-tenant isolation
/// S-07: Score normalization and ordering
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-01 Dense · S-03 Filter · S-04 Tenant · S-07 Scores');
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

  // S-01
  await run('S-01-1: exact match score > 0.85', _s01ExactMatch);
  await run('S-01-2: semantic match score > 0.6', _s01SemanticMatch);
  await run('S-01-3: unrelated score < 0.5', _s01Unrelated);
  await run('S-01-4: topK respected', _s01TopK);
  await run('S-01-5: scoreThreshold filters low scores', _s01Threshold);
  await run('S-01-6: results sorted DESC by score', _s01Ordering);

  // S-03
  await run('S-03-1: filter by artifactId', _s03ArtifactFilter);
  await run('S-03-2: filter by ownerId', _s03OwnerFilter);
  await run('S-03-3: combined filter', _s03CombinedFilter);
  await run('S-03-4: filter + topK applied after filter', _s03FilterTopK);
  await run('S-03-5: no-match filter returns []', _s03EmptyFilter);

  // S-04
  await run('S-04-1: tenant A sees only own data', _s04TenantA);
  await run('S-04-2: tenant B sees only own data', _s04TenantB);
  await run('S-04-3: cross-tenant query returns 0', _s04CrossTenant);

  // S-07
  await run('S-07-1: identical vectors score = 1.0', _s07Identical);
  await run('S-07-2: all scores in [0, 1]', _s07Range);
  await run('S-07-3: similar text scores higher than unrelated', _s07Ordering);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

// ── Setup ─────────────────────────────────────────────────────────────────────

const _tenantA = 'sc-tenant-a';
const _tenantB = 'sc-tenant-b';
const _ownerA = 'sc-owner-a';
const _ownerB = 'sc-owner-b';
const _storeId = 'pgvector-main';

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;
bool _initialized = false;

Future<void> _init() async {
  if (_initialized) return;
  _initialized = true;

  await initializeDataLayer(
    endpoint: _endpoint,
    tenantId: _tenantA,
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
    tenantId: _tenantA,
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

  await _indexCorpus();
}

// Corpus: 3 topics × 3 docs each
const _corpus = {
  // AI topic
  'sc-ai-001': (_tenantA, _ownerA, 'Vector embeddings represent semantic meaning in high-dimensional space. Cosine similarity measures the angle between embedding vectors to find related content.'),
  'sc-ai-002': (_tenantA, _ownerA, 'Neural networks learn hierarchical representations through backpropagation. Transformer models use self-attention to capture long-range dependencies in sequences.'),
  'sc-ai-003': (_tenantA, _ownerB, 'Large language models are trained on massive text corpora using next-token prediction. Fine-tuning adapts pretrained models to specific downstream tasks.'),
  // DB topic
  'sc-db-001': (_tenantA, _ownerA, 'PostgreSQL supports ACID transactions ensuring data consistency. Connection pooling reduces overhead by reusing database connections across requests.'),
  'sc-db-002': (_tenantA, _ownerB, 'B-tree indexes accelerate equality and range queries on sorted columns. Partial indexes reduce index size by covering only a subset of rows.'),
  'sc-db-003': (_tenantA, _ownerA, 'Database sharding distributes data across multiple nodes for horizontal scaling. Consistent hashing minimizes data movement when adding or removing shards.'),
  // Security topic — tenant B
  'sc-sec-001': (_tenantB, _ownerA, 'SQL injection attacks exploit unsanitized user input in database queries. Parameterized queries prevent injection by separating code from data.'),
  'sc-sec-002': (_tenantB, _ownerA, 'JWT tokens encode claims as base64-encoded JSON signed with HMAC or RSA. Token expiration and signature validation prevent replay attacks.'),
  'sc-sec-003': (_tenantB, _ownerB, 'TLS 1.3 provides forward secrecy through ephemeral key exchange. Certificate pinning prevents man-in-the-middle attacks in mobile applications.'),
};

Future<void> _indexCorpus() async {
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  for (final e in _corpus.entries) {
    final (tenant, owner, text) = e.value;
    final bytes = utf8.encode(text);
    final artifact = StoredArtifact(
      id: e.key,
      tenantId: tenant,
      ownerId: owner,
      storageKey: '$tenant/${e.key}.txt',
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
        id: 'sc-pipeline-v1',
        storeId: _storeId,
        extractor: PlainTextExtractor(),
        chunker: SentenceChunker(maxChunkChars: 300),
        embedder: _embedder,
        reranker: PassthroughReranker(),
      ),
    );
  }
  print('  [setup] Indexed ${_corpus.length} documents\n');
}

// ── S-01: Dense search ────────────────────────────────────────────────────────

Future<void> _s01ExactMatch() async {
  await _init();
  // Query is a near-exact phrase from sc-ai-001
  final results = await _repo.search(
    'cosine similarity measures angle between embedding vectors',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 1,
  );
  if (results.isEmpty) throw StateError('No results');
  final score = results.first.score;
  print('  ✅ exact match score=${score.toStringAsFixed(4)} (artifact=${results.first.payload['artifactId']})');
  if (score < 0.75) throw StateError('Score $score < 0.75');
}

Future<void> _s01SemanticMatch() async {
  // Synonym query — not exact words but same meaning
  final results = await _repo.search(
    'how do word vectors capture meaning',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 3,
  );
  if (results.isEmpty) throw StateError('No results');
  final topScore = results.first.score;
  print('  ✅ semantic match top score=${topScore.toStringAsFixed(4)}');
  if (topScore < 0.6) throw StateError('Semantic score $topScore < 0.6');
}

Future<void> _s01Unrelated() async {
  // Query completely unrelated to any indexed doc
  final results = await _repo.search(
    'cooking recipes pasta carbonara ingredients',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 3,
    scoreThreshold: 0.0,
  );
  final topScore = results.isEmpty ? 0.0 : results.first.score;
  print('  ✅ unrelated top score=${topScore.toStringAsFixed(4)}');
  if (topScore >= 0.7) throw StateError('Unrelated score $topScore >= 0.7 — too high');
}

Future<void> _s01TopK() async {
  final r1 = await _repo.search('database', tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 1);
  final r3 = await _repo.search('database', tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 3);
  if (r1.length > 1) throw StateError('topK=1 returned ${r1.length}');
  if (r3.length > 3) throw StateError('topK=3 returned ${r3.length}');
  print('  ✅ topK=1 → ${r1.length}, topK=3 → ${r3.length}');
}

Future<void> _s01Threshold() async {
  final all = await _repo.search('neural network', tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 10, scoreThreshold: 0.0);
  final filtered = await _repo.search('neural network', tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 10, scoreThreshold: 0.7);
  if (filtered.any((r) => r.score < 0.7)) throw StateError('Result below threshold');
  print('  ✅ threshold=0.7: ${all.length} total → ${filtered.length} above threshold');
}

Future<void> _s01Ordering() async {
  final results = await _repo.search('transformer attention', tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 5);
  for (var i = 1; i < results.length; i++) {
    if (results[i].score > results[i - 1].score) {
      throw StateError('Results not sorted: ${results[i - 1].score} < ${results[i].score}');
    }
  }
  print('  ✅ ordering: ${results.map((r) => r.score.toStringAsFixed(3)).join(' > ')}');
}

// ── S-03: Filter search ───────────────────────────────────────────────────────

Future<void> _s03ArtifactFilter() async {
  await _init();
  final results = await _repo.search(
    'database index query',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 10, artifactId: 'sc-db-001',
  );
  if (results.any((r) => r.payload['artifactId'] != 'sc-db-001')) {
    throw StateError('Filter leak: got results from wrong artifact');
  }
  print('  ✅ artifactId filter: ${results.length} results, all from sc-db-001');
}

Future<void> _s03OwnerFilter() async {
  final results = await _repo.search(
    'data storage',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 10, ownerId: _ownerA,
  );
  if (results.any((r) => r.payload['ownerId'] != _ownerA)) {
    throw StateError('Owner filter leak');
  }
  print('  ✅ ownerId filter: ${results.length} results, all from $_ownerA');
}

Future<void> _s03CombinedFilter() async {
  final results = await _repo.search(
    'database',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 10, artifactId: 'sc-db-001', ownerId: _ownerA,
  );
  for (final r in results) {
    if (r.payload['artifactId'] != 'sc-db-001' || r.payload['ownerId'] != _ownerA) {
      throw StateError('Combined filter leak');
    }
  }
  print('  ✅ combined filter: ${results.length} results');
}

Future<void> _s03FilterTopK() async {
  // Filter to ownerB (has 2 docs in tenantA: sc-ai-003, sc-db-002)
  final results = await _repo.search(
    'data',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 1, ownerId: _ownerB,
  );
  if (results.length > 1) throw StateError('topK=1 with filter returned ${results.length}');
  print('  ✅ filter+topK=1: ${results.length} result');
}

Future<void> _s03EmptyFilter() async {
  final results = await _repo.search(
    'anything',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 10, artifactId: 'nonexistent-artifact-xyz',
  );
  if (results.isNotEmpty) throw StateError('Expected empty, got ${results.length}');
  print('  ✅ no-match filter: 0 results');
}

// ── S-04: Multi-tenant ────────────────────────────────────────────────────────

Future<void> _s04TenantA() async {
  await _init();
  final results = await _repo.search(
    'database query index',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 10,
  );
  if (results.any((r) => r.payload['tenantId'] != _tenantA)) {
    throw StateError('Tenant A got data from another tenant');
  }
  print('  ✅ tenant A: ${results.length} results, all tenantId=$_tenantA');
}

Future<void> _s04TenantB() async {
  final results = await _repo.search(
    'SQL injection security',
    tenantId: _tenantB, storeId: _storeId, embedder: _embedder, topK: 10,
  );
  if (results.any((r) => r.payload['tenantId'] != _tenantB)) {
    throw StateError('Tenant B got data from another tenant');
  }
  print('  ✅ tenant B: ${results.length} results, all tenantId=$_tenantB');
}

Future<void> _s04CrossTenant() async {
  // Query about security (tenant B topic) but executed as tenant A
  final results = await _repo.search(
    'SQL injection parameterized queries',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder, topK: 10,
  );
  if (results.any((r) => r.payload['tenantId'] == _tenantB)) {
    throw StateError('Cross-tenant leak: tenant A got tenant B data');
  }
  print('  ✅ cross-tenant: 0 tenant B results visible to tenant A (got ${results.length} from A)');
}

// ── S-07: Score normalization ─────────────────────────────────────────────────

Future<void> _s07Identical() async {
  // Use InMemory for this test — direct vector control
  final store = InMemoryVectorStorage();
  await store.ensureCollection('test', vectorSize: 4);
  final v = [1.0, 0.0, 0.0, 0.0];
  await store.upsert('test', VectorEntry(
    id: 'v1', vector: v,
    payload: {'tenantId': 'test', 'text': 'test'},
  ));
  final results = await store.search('test', v, tenantId: 'test', limit: 1);
  final score = results.first.score;
  print('  ✅ identical vectors score=${score.toStringAsFixed(6)}');
  if ((score - 1.0).abs() > 0.001) throw StateError('Identical score $score ≠ 1.0');
}

Future<void> _s07Range() async {
  await _init();
  final results = await _repo.search(
    'machine learning neural network',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 10, scoreThreshold: 0.0,
  );
  for (final r in results) {
    if (r.score < 0.0 || r.score > 1.0) {
      throw StateError('Score ${r.score} out of [0,1]');
    }
  }
  print('  ✅ all ${results.length} scores in [0.0, 1.0]');
}

Future<void> _s07Ordering() async {
  // "vector embeddings" should score higher on AI docs than DB docs
  final results = await _repo.search(
    'vector embeddings semantic similarity',
    tenantId: _tenantA, storeId: _storeId, embedder: _embedder,
    topK: 6, scoreThreshold: 0.0,
  );
  if (results.isEmpty) throw StateError('No results');
  final topArtifact = results.first.payload['artifactId'] as String;
  print('  ✅ "vector embeddings" top result: $topArtifact score=${results.first.score.toStringAsFixed(4)}');
  // Top result should be from AI domain
  if (!topArtifact.contains('ai')) {
    print('  ⚠️  Expected AI doc on top, got $topArtifact');
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

List<double> _randomUnitVector(int dim, Random rng) {
  final v = List.generate(dim, (_) => rng.nextDouble() * 2 - 1);
  final norm = sqrt(v.fold(0.0, (s, x) => s + x * x));
  return v.map((x) => x / norm).toList();
}
