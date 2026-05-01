/// S-10: Index → Reindex → Delete lifecycle
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'lc-tenant';
const _storeId = 'pgvector-main';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-10: Index → Reindex → Delete Lifecycle');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('S-10-1: index v1, search finds v1 content', _s10IndexV1);
  await run('S-10-2: status=indexed after index', _s10StatusIndexed);
  await run('S-10-3: reindex v2, v1 content not found', _s10ReindexV2);
  await run('S-10-4: v2 content found after reindex', _s10SearchV2);
  await run('S-10-5: chunkCount updated after reindex', _s10ChunkCount);
  await run('S-10-6: delete, search returns 0', _s10Delete);
  await run('S-10-7: re-index after delete works', _s10ReIndexAfterDelete);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

const _artId = 'lc-art-001';
const _v1Text = 'Quantum computing uses qubits that can exist in superposition. Quantum entanglement enables instantaneous correlation between particles.';
const _v2Text = 'Blockchain technology uses distributed ledger for immutable record keeping. Smart contracts execute automatically when predefined conditions are met.';

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;
late DirectRepository<StoredArtifact> _artifactRepo;
bool _init = false;

Future<void> _setup() async {
  if (_init) return;
  _init = true;
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenantId, useBuffer: false, authToken: 'test-admin-token');
  _embedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final registry = VectorStoreRegistryImpl();
  registry.register(VectorStoreDescriptor(id: _storeId, type: 'pgvector', embedderId: _embedder.id, vectorDim: _embedder.dimensions), RemoteVectorStorage(remote: remote));
  _artifactRepo = IDataLayer.instance.direct<StoredArtifact>(collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap);
  _repo = VectorRepositoryImpl(registry: registry, artifactRepo: _artifactRepo);
}

IndexingPipeline _pipeline() => IndexingPipeline(id: 'lc-pipeline-v1', storeId: _storeId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 300), embedder: _embedder, reranker: PassthroughReranker());

StoredArtifact _artifact(String text) {
  final bytes = utf8.encode(text);
  return StoredArtifact(id: _artId, tenantId: _tenantId, ownerId: 'lc-owner', storageKey: '$_tenantId/$_artId.txt', fileName: '$_artId.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
}

Future<void> _s10IndexV1() async {
  await _setup();
  final art = _artifact(_v1Text);
  await _artifactRepo.save(art);
  final result = await _repo.index(art, utf8.encode(_v1Text), _pipeline());
  if (!result.isSuccess) throw StateError('Index failed: ${result.error}');
  print('  ✅ indexed v1: ${result.chunksCreated} chunks');
}

Future<void> _s10StatusIndexed() async {
  final art = await _artifactRepo.findById(_artId);
  if (art?.indexingStatus != IndexingStatus.indexed) throw StateError('Expected indexed, got ${art?.indexingStatus}');
  print('  ✅ status=indexed chunkCount=${art?.chunkCount}');
}

Future<void> _s10ReindexV2() async {
  final art = _artifact(_v2Text);
  await _artifactRepo.save(art);
  await _repo.reindex(art, utf8.encode(_v2Text), _pipeline());
  // v1 content should not be found
  final results = await _repo.search('quantum computing qubits superposition', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 5, artifactId: _artId, scoreThreshold: 0.7);
  print('  ✅ v1 content after reindex: ${results.length} results above 0.7 (expected 0)');
  if (results.isNotEmpty) throw StateError('v1 content still found after reindex');
}

Future<void> _s10SearchV2() async {
  final results = await _repo.search('blockchain distributed ledger smart contracts', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 3, artifactId: _artId);
  if (results.isEmpty) throw StateError('v2 content not found');
  print('  ✅ v2 content found: score=${results.first.score.toStringAsFixed(4)}');
}

Future<void> _s10ChunkCount() async {
  final art = await _artifactRepo.findById(_artId);
  if (art?.chunkCount == null || art!.chunkCount! == 0) throw StateError('chunkCount not updated');
  print('  ✅ chunkCount=${art.chunkCount} storeId=${art.indexedStoreId}');
}

Future<void> _s10Delete() async {
  await _repo.deleteDocument(_artId, _tenantId, _storeId);
  final results = await _repo.search('blockchain', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 5, artifactId: _artId);
  if (results.isNotEmpty) throw StateError('Chunks still found after delete');
  print('  ✅ deleted: 0 chunks remain');
}

Future<void> _s10ReIndexAfterDelete() async {
  final art = _artifact(_v1Text);
  await _artifactRepo.save(art);
  final result = await _repo.index(art, utf8.encode(_v1Text), _pipeline());
  if (!result.isSuccess) throw StateError('Re-index after delete failed');
  print('  ✅ re-indexed after delete: ${result.chunksCreated} chunks');
}
