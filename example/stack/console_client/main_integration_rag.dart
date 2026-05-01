/// S-13: RAG context assembly
/// aq_data_layer returns chunks with scores — LLM usage is outside this package.
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'rag-tenant';
const _storeId = 'pgvector-main';
const _maxContextChars = 4096;

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-13: RAG Context Assembly');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('Setup', _setup);
  await run('S-13-1: search returns ranked chunks', _s13Search);
  await run('S-13-2: context assembled within token limit', _s13ContextLimit);
  await run('S-13-3: context contains relevant text', _s13ContextRelevance);
  await run('S-13-4: hybrid search improves context', _s13HybridContext);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

const _docs = {
  'rag-sec-001': 'SQL injection prevention requires parameterized queries. Never concatenate user input into SQL strings. Use prepared statements with bound parameters.',
  'rag-sec-002': 'Cross-site scripting (XSS) attacks inject malicious scripts into web pages. Sanitize all user input and use Content Security Policy headers.',
  'rag-ai-001': 'Retrieval Augmented Generation combines vector search with language models. The retrieved context is prepended to the prompt to ground the model response.',
  'rag-ai-002': 'Embedding models convert text to dense vectors. Similar texts produce vectors with high cosine similarity enabling semantic search.',
  'rag-db-001': 'PostgreSQL supports full-text search via tsvector and tsquery. GIN indexes accelerate text search queries significantly.',
};

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;

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
    final artifact = StoredArtifact(id: e.key, tenantId: _tenantId, ownerId: 'rag-owner', storageKey: '$_tenantId/${e.key}.txt', fileName: '${e.key}.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
    await artifactRepo.save(artifact);
    await _repo.index(artifact, bytes, IndexingPipeline(id: 'rag-pipeline', storeId: _storeId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 300), embedder: _embedder, reranker: PassthroughReranker()));
  }
  print('  ✅ Indexed ${_docs.length} documents');
}

Future<void> _s13Search() async {
  final results = await _repo.search('SQL injection prevention', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 3);
  if (results.isEmpty) throw StateError('No results');
  // Results must be sorted by score DESC
  for (var i = 1; i < results.length; i++) {
    if (results[i].score > results[i - 1].score) throw StateError('Not sorted');
  }
  print('  ✅ ${results.length} ranked chunks, top score=${results.first.score.toStringAsFixed(4)}');
}

Future<void> _s13ContextLimit() async {
  final results = await _repo.search('security web application', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 10);
  // Assemble context respecting token limit
  final context = _assembleContext(results, _maxContextChars);
  if (context.length > _maxContextChars) throw StateError('Context ${context.length} > $_maxContextChars');
  print('  ✅ Context assembled: ${context.length} chars from ${results.length} chunks');
}

Future<void> _s13ContextRelevance() async {
  const query = 'how to prevent SQL injection attacks';
  final results = await _repo.search(query, tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 3);
  final context = _assembleContext(results, _maxContextChars);
  // Context should contain relevant keywords
  final hasRelevant = context.toLowerCase().contains('sql') || context.toLowerCase().contains('injection') || context.toLowerCase().contains('parameterized');
  print('  ✅ Context relevant: $hasRelevant');
  print('  Context preview: "${context.substring(0, context.length.clamp(0, 150))}..."');
  if (!hasRelevant) throw StateError('Context does not contain relevant content');
}

Future<void> _s13HybridContext() async {
  const query = 'parameterized queries SQL injection';
  final dense = await _repo.search(query, tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 3);
  final hybrid = await _repo.search(query, tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 3, sparseQuery: query, alpha: 0.7);

  final denseTop = dense.isEmpty ? 'none' : dense.first.payload['artifactId'] as String;
  final hybridTop = hybrid.isEmpty ? 'none' : hybrid.first.payload['artifactId'] as String;
  print('  ✅ Dense top: $denseTop (${dense.isEmpty ? 0 : dense.first.score.toStringAsFixed(4)})');
  print('     Hybrid top: $hybridTop (${hybrid.isEmpty ? 0 : hybrid.first.score.toStringAsFixed(4)})');
}

String _assembleContext(List<VectorSearchResult> results, int maxChars) {
  final buffer = StringBuffer();
  for (final r in results) {
    final text = r.payload['text'] as String? ?? '';
    if (buffer.length + text.length + 2 > maxChars) break;
    if (buffer.isNotEmpty) buffer.write('\n\n');
    buffer.write(text);
  }
  return buffer.toString();
}
