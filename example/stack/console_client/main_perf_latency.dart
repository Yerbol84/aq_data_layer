/// S-15: Search latency benchmark
/// p50, p95, p99 for single and parallel search
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'perf-tenant';
const _storeId = 'pgvector-main';
const _docCount = 10;
const _chunksPerDoc = 10; // ~100 total chunks
const _warmupRuns = 5;
const _benchRuns = 50;

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-15: Search Latency Benchmark');
  print('  Corpus: $_docCount docs × $_chunksPerDoc chunks = ${_docCount * _chunksPerDoc} chunks');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('Setup: index corpus', _setup);
  await run('S-15-1: single search latency p95 < 500ms', _s15SingleLatency);
  await run('S-15-2: batch parallel search', _s15BatchLatency);
  await run('S-15-3: hybrid search latency', _s15HybridLatency);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;

final _queries = [
  'machine learning neural network',
  'database query optimization',
  'security authentication token',
  'distributed system consensus',
  'vector similarity search',
];

Future<void> _setup() async {
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenantId, useBuffer: false, authToken: 'test-admin-token');
  _embedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final registry = VectorStoreRegistryImpl();
  registry.register(VectorStoreDescriptor(id: _storeId, type: 'pgvector', embedderId: _embedder.id, vectorDim: _embedder.dimensions), RemoteVectorStorage(remote: remote));
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap);
  _repo = VectorRepositoryImpl(registry: registry, artifactRepo: artifactRepo);

  // Index corpus: each doc has multiple sentences = multiple chunks
  final topics = ['machine learning', 'database systems', 'network security', 'distributed computing', 'vector search', 'cloud infrastructure', 'software architecture', 'data pipelines', 'API design', 'performance optimization'];
  for (var i = 0; i < _docCount; i++) {
    final topic = topics[i % topics.length];
    final text = List.generate(_chunksPerDoc, (j) => 'This is sentence $j about $topic. It covers important aspects of $topic in detail. Understanding $topic requires knowledge of related concepts.').join(' ');
    final bytes = utf8.encode(text);
    final id = 'perf-doc-${i.toString().padLeft(2, '0')}';
    final artifact = StoredArtifact(id: id, tenantId: _tenantId, ownerId: 'perf-owner', storageKey: '$_tenantId/$id.txt', fileName: '$id.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
    await artifactRepo.save(artifact);
    await _repo.index(artifact, bytes, IndexingPipeline(id: 'perf-pipeline', storeId: _storeId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 200), embedder: _embedder, reranker: PassthroughReranker()));
  }
  print('  ✅ Indexed $_docCount documents');
}

Future<void> _s15SingleLatency() async {
  // Warmup
  for (var i = 0; i < _warmupRuns; i++) {
    await _repo.search(_queries[i % _queries.length], tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 10);
  }

  // Benchmark
  final latencies = <int>[];
  for (var i = 0; i < _benchRuns; i++) {
    final sw = Stopwatch()..start();
    await _repo.search(_queries[i % _queries.length], tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 10);
    sw.stop();
    latencies.add(sw.elapsedMilliseconds);
  }

  latencies.sort();
  final p50 = latencies[(_benchRuns * 0.50).floor()];
  final p95 = latencies[(_benchRuns * 0.95).floor()];
  final p99 = latencies[(_benchRuns * 0.99).floor()];
  final avg = latencies.reduce((a, b) => a + b) ~/ latencies.length;

  print('  ✅ Single search ($_benchRuns runs): avg=${avg}ms p50=${p50}ms p95=${p95}ms p99=${p99}ms');
  if (p95 > 500) throw StateError('p95 ${p95}ms > 500ms');
}

Future<void> _s15BatchLatency() async {
  const batchSize = 10;
  final sw = Stopwatch()..start();
  await Future.wait(List.generate(batchSize, (i) =>
    _repo.search(_queries[i % _queries.length], tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 5)
  ));
  sw.stop();
  print('  ✅ Batch $batchSize parallel searches: ${sw.elapsedMilliseconds}ms total (${sw.elapsedMilliseconds ~/ batchSize}ms avg)');
}

Future<void> _s15HybridLatency() async {
  final latencies = <int>[];
  for (var i = 0; i < 20; i++) {
    final q = _queries[i % _queries.length];
    final sw = Stopwatch()..start();
    await _repo.search(q, tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 10, sparseQuery: q, alpha: 0.7);
    sw.stop();
    latencies.add(sw.elapsedMilliseconds);
  }
  latencies.sort();
  final p95 = latencies[(20 * 0.95).floor()];
  print('  ✅ Hybrid search (20 runs): p95=${p95}ms');
}
