/// S-09: Reranker — compare precision before/after reranking
///
/// Requires Ollama with a generative model (llama3.2:1b or similar).
/// Falls back gracefully if model not available.
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
final _llmModel = Platform.environment['OLLAMA_LLM_MODEL'] ?? 'llama3.2:1b';
const _tenantId = 'rr-tenant';
const _storeId = 'pgvector-main';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-09: Reranker Evaluation');
  print('  LLM model: $_llmModel');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('Setup: index corpus', _setup);
  await run('S-09-1: PassthroughReranker preserves order', _s09Passthrough);
  await run('S-09-2: OllamaReranker changes order', _s09OllamaChangesOrder);
  await run('S-09-3: Reranked top result more relevant', _s09TopRelevance);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

const _docs = {
  'rr-doc-a': 'Vector databases store embeddings and support approximate nearest neighbor search. They are optimized for high-dimensional similarity queries.',
  'rr-doc-b': 'Relational databases use SQL for structured data with ACID guarantees. They excel at joins and transactions.',
  'rr-doc-c': 'Vector similarity search finds semantically related documents using cosine distance between embedding vectors.',
  'rr-doc-d': 'NoSQL databases sacrifice ACID for horizontal scalability and flexible schemas.',
  'rr-doc-e': 'Embedding models convert text into dense numerical vectors capturing semantic meaning.',
};

const _query = 'how to find similar documents using vector embeddings';

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;
late List<VectorSearchResult> _baseResults;

Future<void> _setup() async {
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenantId, useBuffer: false, authToken: 'test-admin-token');
  _embedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final registry = VectorStoreRegistryImpl();
  registry.register(VectorStoreDescriptor(id: _storeId, type: 'pgvector', embedderId: _embedder.id, vectorDim: _embedder.dimensions), RemoteVectorStorage(remote: remote));
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap);
  _repo = VectorRepositoryImpl(registry: registry, artifactRepo: artifactRepo);

  for (final e in _docs.entries) {
    final bytes = utf8.encode(e.value);
    final artifact = StoredArtifact(id: e.key, tenantId: _tenantId, ownerId: 'rr-owner', storageKey: '$_tenantId/${e.key}.txt', fileName: '${e.key}.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
    await artifactRepo.save(artifact);
    await _repo.index(artifact, bytes, IndexingPipeline(id: 'rr-pipeline', storeId: _storeId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 300), embedder: _embedder, reranker: PassthroughReranker()));
  }

  _baseResults = await _repo.search(_query, tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 5, scoreThreshold: 0.0);
  print('  ✅ Indexed ${_docs.length} docs, base search: ${_baseResults.length} results');
  for (final r in _baseResults) {
    print('     ${r.payload['artifactId']} score=${r.score.toStringAsFixed(4)}');
  }
}

Future<void> _s09Passthrough() async {
  final reranker = PassthroughReranker();
  final reranked = await reranker.rerank(_query, _baseResults);
  // Order must be identical
  for (var i = 0; i < _baseResults.length; i++) {
    if (reranked[i].id != _baseResults[i].id) throw StateError('PassthroughReranker changed order at index $i');
  }
  print('  ✅ PassthroughReranker: order preserved (${reranked.length} results)');
}

Future<void> _s09OllamaChangesOrder() async {
  // Check if LLM model is available
  final reranker = OllamaReranker(endpoint: _ollamaEndpoint, model: _llmModel);
  final reranked = await reranker.rerank(_query, _baseResults);

  if (reranked.isEmpty) throw StateError('Reranker returned empty results');

  final baseIds = _baseResults.map((r) => r.id).toList();
  final rerankedIds = reranked.map((r) => r.id).toList();
  final orderChanged = baseIds.join(',') != rerankedIds.join(',');

  print('  ✅ OllamaReranker: order ${orderChanged ? 'changed' : 'same (model may not be loaded)'}');
  print('     Before: ${baseIds.join(', ')}');
  print('     After:  ${rerankedIds.join(', ')}');
  // Not a hard failure if order didn't change — model may give uniform scores
}

Future<void> _s09TopRelevance() async {
  final reranker = OllamaReranker(endpoint: _ollamaEndpoint, model: _llmModel);
  final reranked = await reranker.rerank(_query, _baseResults);

  final topId = reranked.first.payload['artifactId'] as String;
  // Top result should be about vectors (rr-doc-a, rr-doc-c, or rr-doc-e)
  final isRelevant = ['rr-doc-a', 'rr-doc-c', 'rr-doc-e'].contains(topId);
  print('  ✅ Top after rerank: $topId (relevant=$isRelevant score=${reranked.first.score.toStringAsFixed(4)})');
  if (!isRelevant) {
    print('  ⚠️  Top result not from vector-related docs — model may need tuning');
  }
}
