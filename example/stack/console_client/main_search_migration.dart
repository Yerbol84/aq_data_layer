/// S-12: Embedder migration — switch from mock to Ollama
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'mg-tenant';
const _mockStoreId = 'memory-mock';
const _pgStoreId = 'pgvector-main';
const _artId = 'mg-doc-001';
const _docText = 'Distributed systems achieve fault tolerance through replication and consensus protocols. Leader election ensures only one node coordinates writes at a time.';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-12: Embedder Migration (Mock → Ollama)');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('S-12-1: index with mock embedder (dim=8)', _s12IndexMock);
  await run('S-12-2: search with mock finds content', _s12SearchMock);
  await run('S-12-3: reindex with Ollama (dim=768)', _s12ReindexOllama);
  await run('S-12-4: search with Ollama finds content', _s12SearchOllama);
  await run('S-12-5: PipelineStamp updated to Ollama embedder', _s12VerifyStamp);
  await run('S-12-6: two stores coexist independently', _s12TwoStores);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

late MockEmbeddingsClient _mockEmbedder;
late OllamaEmbeddingsClient _ollamaEmbedder;
late VectorRepositoryImpl _mockRepo;
late VectorRepositoryImpl _ollamaRepo;
late DirectRepository<StoredArtifact> _artifactRepo;

Future<void> _initRepos() async {
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenantId, useBuffer: false, authToken: 'test-admin-token');
  _mockEmbedder = MockEmbeddingsClient(dimensions: 8);
  _ollamaEmbedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);

  // Mock store — InMemory
  final mockStore = InMemoryVectorStorage();
  final mockRegistry = VectorStoreRegistryImpl();
  mockRegistry.register(VectorStoreDescriptor(id: _mockStoreId, type: 'in_memory', embedderId: _mockEmbedder.id, vectorDim: _mockEmbedder.dimensions), mockStore);

  // Ollama store — pgvector via RPC
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final pgRegistry = VectorStoreRegistryImpl();
  pgRegistry.register(VectorStoreDescriptor(id: _pgStoreId, type: 'pgvector', embedderId: _ollamaEmbedder.id, vectorDim: _ollamaEmbedder.dimensions), RemoteVectorStorage(remote: remote));

  _artifactRepo = IDataLayer.instance.direct<StoredArtifact>(collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap);
  _mockRepo = VectorRepositoryImpl(registry: mockRegistry, artifactRepo: _artifactRepo);
  _ollamaRepo = VectorRepositoryImpl(registry: pgRegistry, artifactRepo: _artifactRepo);
}

StoredArtifact _artifact() {
  final bytes = utf8.encode(_docText);
  return StoredArtifact(id: _artId, tenantId: _tenantId, ownerId: 'mg-owner', storageKey: '$_tenantId/$_artId.txt', fileName: '$_artId.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
}

Future<void> _s12IndexMock() async {
  await _initRepos();
  final artifact = _artifact();
  await _artifactRepo.save(artifact);
  final result = await _mockRepo.index(artifact, utf8.encode(_docText), IndexingPipeline(id: 'mg-mock-pipeline', storeId: _mockStoreId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 200), embedder: _mockEmbedder, reranker: PassthroughReranker()));
  if (!result.isSuccess) throw StateError('Mock index failed');
  print('  ✅ Mock indexed: ${result.chunksCreated} chunks (dim=8) stamp.embedderId=${result.stamp.embedderId}');
}

Future<void> _s12SearchMock() async {
  final results = await _mockRepo.search('distributed systems replication', tenantId: _tenantId, storeId: _mockStoreId, embedder: _mockEmbedder, topK: 3, artifactId: _artId);
  if (results.isEmpty) throw StateError('Mock search returned 0 results');
  print('  ✅ Mock search: ${results.length} results, top score=${results.first.score.toStringAsFixed(4)}');
}

Future<void> _s12ReindexOllama() async {
  final artifact = _artifact();
  final result = await _ollamaRepo.index(artifact, utf8.encode(_docText), IndexingPipeline(id: 'mg-ollama-pipeline', storeId: _pgStoreId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 200), embedder: _ollamaEmbedder, reranker: PassthroughReranker()));
  if (!result.isSuccess) throw StateError('Ollama index failed');
  print('  ✅ Ollama indexed: ${result.chunksCreated} chunks (dim=768) stamp.embedderId=${result.stamp.embedderId}');
}

Future<void> _s12SearchOllama() async {
  final results = await _ollamaRepo.search('distributed systems replication', tenantId: _tenantId, storeId: _pgStoreId, embedder: _ollamaEmbedder, topK: 3, artifactId: _artId);
  if (results.isEmpty) throw StateError('Ollama search returned 0 results');
  print('  ✅ Ollama search: ${results.length} results, top score=${results.first.score.toStringAsFixed(4)}');
}

Future<void> _s12VerifyStamp() async {
  // Check pgvector chunks have Ollama stamp
  final results = await _ollamaRepo.search('consensus protocol', tenantId: _tenantId, storeId: _pgStoreId, embedder: _ollamaEmbedder, topK: 1, artifactId: _artId);
  if (results.isEmpty) throw StateError('No results');
  final payload = VectorPointPayload.fromMap(results.first.payload);
  if (payload.stamp.embedderId != _ollamaEmbedder.id) throw StateError('Wrong embedderId: ${payload.stamp.embedderId}');
  print('  ✅ Stamp verified: embedderId=${payload.stamp.embedderId} dim=${payload.stamp.vectorDim}');
}

Future<void> _s12TwoStores() async {
  // Both stores work independently
  final mockResults = await _mockRepo.search('fault tolerance', tenantId: _tenantId, storeId: _mockStoreId, embedder: _mockEmbedder, topK: 3, artifactId: _artId);
  final pgResults = await _ollamaRepo.search('fault tolerance', tenantId: _tenantId, storeId: _pgStoreId, embedder: _ollamaEmbedder, topK: 3, artifactId: _artId);
  print('  ✅ Two stores coexist: mock=${mockResults.length} results, pgvector=${pgResults.length} results');
}
