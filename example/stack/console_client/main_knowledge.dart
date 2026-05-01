/// AQ Data Layer — Knowledge Pipeline Scenarios
///
/// Full end-to-end: upload artifact → index → annotate → search → verify
///
/// Сценарии:
///   1. Upload + Index  — загрузить файл, проиндексировать
///   2. Search          — семантический поиск по содержимому
///   3. Annotate user   — highlight аннотация от пользователя
///   4. Annotate LLM    — vectorRef аннотация с chunkId из поиска
///   5. Verify link     — аннотация ссылается на реальный chunkId
///   6. Reindex         — обновить файл, переиндексировать
///   7. Delete artifact — удалить файл + чанки
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint =
    Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';

const _tenantId = 'tenant-knowledge-test';
const _ownerId = 'user-know-001';
const _storeId = 'memory-knowledge';
const _artifactId = 'know-doc-001';

final _docContent = '''# Knowledge Base Document

## Introduction

Artificial intelligence and machine learning are transforming industries.
Deep learning models can process vast amounts of data efficiently.

## Vector Search

Semantic search uses embeddings to find conceptually similar content.
Unlike keyword search, it understands meaning and context.
Cosine similarity measures the angle between vectors in high-dimensional space.

## Applications

RAG (Retrieval Augmented Generation) combines search with language models.
It retrieves relevant context before generating responses.
This improves accuracy and reduces hallucinations significantly.
''';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — Knowledge Pipeline Scenarios');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;

  Future<void> run(String name, Future<void> Function() fn) async {
    try {
      await fn();
      passed++;
    } catch (e, st) {
      print('  ❌ FAILED: $e');
      print('     $st');
      failed++;
    }
  }

  await run('1. Upload + Index', _scenarioUploadIndex);
  await run('2. Semantic search', _scenarioSearch);
  await run('3. User annotation (highlight)', _scenarioUserAnnotation);
  await run('4. LLM annotation (vectorRef)', _scenarioLlmAnnotation);
  await run('5. Verify annotation → chunk link', _scenarioVerifyLink);
  await run('6. Reindex updated content', _scenarioReindex);
  await run('7. Delete artifact + chunks', _scenarioDelete);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

// ── Shared state ──────────────────────────────────────────────────────────────

final _embedder = MockEmbeddingsClient(dimensions: 8);
final _registry = VectorStoreRegistryImpl();
late VectorRepositoryImpl _vectorRepo;
late String _foundChunkId;

Future<void> _initDataLayer() async {
  await initializeDataLayer(
    endpoint: _endpoint,
    tenantId: _tenantId,
    useBuffer: false,
    authToken: 'test-admin-token',
  );
  final store = InMemoryVectorStorage();
  _registry.register(
    VectorStoreDescriptor(
      id: _storeId,
      type: 'in_memory',
      embedderId: _embedder.id,
      vectorDim: _embedder.dimensions,
    ),
    store,
  );
  _vectorRepo = VectorRepositoryImpl(
    registry: _registry,
    artifactRepo: IDataLayer.instance.direct<StoredArtifact>(
      collection: StoredArtifact.kCollection,
      fromMap: StoredArtifact.fromMap,
    ),
    pipelineRepo: IDataLayer.instance.direct<IndexingPipelineRecord>(
      collection: IndexingPipelineRecord.kCollection,
      fromMap: IndexingPipelineRecord.fromMap,
    ),
  );
}

IndexingPipeline _pipeline() => IndexingPipeline(
      id: 'knowledge-pipeline-v1',
      storeId: _storeId,
      extractor: PlainTextExtractor(),
      chunker: MockChunker(maxChunkSize: 150),
      embedder: _embedder,
      reranker: PassthroughReranker(),
    );

// ── 1. Upload + Index ─────────────────────────────────────────────────────────

Future<void> _scenarioUploadIndex() async {
  await _initDataLayer();

  // Upload bytes via RemoteArtifactStorage
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final artifactStorage = RemoteArtifactStorage(remote: remote);
  final bytes = utf8.encode(_docContent);
  final key = '$_tenantId/$_artifactId/content.md';
  await artifactStorage.put(key, bytes, contentType: 'text/markdown');

  // Save metadata
  final artifact = StoredArtifact(
    id: _artifactId,
    tenantId: _tenantId,
    ownerId: _ownerId,
    storageKey: key,
    fileName: 'knowledge-doc.md',
    contentType: 'text/markdown',
    sizeBytes: bytes.length,
    checksum: bytes.length.toString(),
    createdAt: DateTime.now().toUtc(),
  );
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );
  await artifactRepo.save(artifact);

  // Index
  final result = await _vectorRepo.index(artifact, bytes, _pipeline());
  if (!result.isSuccess) throw StateError('Index failed: ${result.error}');
  print('  ✅ Uploaded + indexed: ${result.chunksCreated} chunks');
}

// ── 2. Semantic search ────────────────────────────────────────────────────────

Future<void> _scenarioSearch() async {
  final results = await _vectorRepo.search(
    'vector embeddings similarity search',
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: 3,
  );
  if (results.isEmpty) throw StateError('No search results');
  _foundChunkId = results.first.id;
  print('  ✅ Search: ${results.length} results, top chunk: $_foundChunkId');
  for (final r in results) {
    final p = VectorPointPayload.fromMap(r.payload);
    print('     • score=${r.score.toStringAsFixed(4)} text="${p.text.substring(0, p.text.length.clamp(0, 50))}..."');
  }
}

// ── 3. User annotation ────────────────────────────────────────────────────────

Future<void> _scenarioUserAnnotation() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );
  final annotation = DocumentAnnotation(
    id: 'know-annot-user-001',
    tenantId: _tenantId,
    ownerId: _ownerId,
    artifactId: _artifactId,
    actorType: AnnotationActorType.user,
    actorId: _ownerId,
    type: AnnotationType.highlight,
    range: const AnnotationRange(startOffset: 100, endOffset: 200),
    content: 'Key section about vector search',
    createdAt: DateTime.now().toUtc(),
  );
  await repo.save(annotation, actorId: _ownerId);
  print('  ✅ User annotation: ${annotation.id} [${annotation.type.value}]');
}

// ── 4. LLM annotation ─────────────────────────────────────────────────────────

Future<void> _scenarioLlmAnnotation() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );
  final annotation = DocumentAnnotation(
    id: 'know-annot-llm-001',
    tenantId: _tenantId,
    ownerId: _ownerId,
    artifactId: _artifactId,
    actorType: AnnotationActorType.llm,
    actorId: 'mock-embedder-v1',
    type: AnnotationType.vectorRef,
    range: const AnnotationRange(startOffset: 0, endOffset: 150),
    content: 'Semantically relevant chunk for query: vector embeddings',
    meta: {
      'chunkId': _foundChunkId,
      'score': 0.95,
      'storeId': _storeId,
    },
    createdAt: DateTime.now().toUtc(),
  );
  await repo.save(annotation, actorId: 'mock-embedder-v1');
  print('  ✅ LLM annotation: ${annotation.id} chunkId=$_foundChunkId');
}

// ── 5. Verify annotation → chunk link ────────────────────────────────────────

Future<void> _scenarioVerifyLink() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );
  final annotation = await repo.findById('know-annot-llm-001');
  if (annotation == null) throw StateError('LLM annotation not found');

  final chunkId = annotation.meta['chunkId'] as String?;
  if (chunkId == null) throw StateError('No chunkId in annotation meta');
  if (chunkId != _foundChunkId) {
    throw StateError('chunkId mismatch: $chunkId != $_foundChunkId');
  }
  print('  ✅ Annotation → chunk link verified: $chunkId');
}

// ── 6. Reindex ────────────────────────────────────────────────────────────────

Future<void> _scenarioReindex() async {
  final updatedContent = _docContent + '\n## New Section\nAdded after update.\n';
  final bytes = utf8.encode(updatedContent);
  final artifact = StoredArtifact(
    id: _artifactId,
    tenantId: _tenantId,
    ownerId: _ownerId,
    storageKey: '$_tenantId/$_artifactId/content.md',
    fileName: 'knowledge-doc.md',
    contentType: 'text/markdown',
    sizeBytes: bytes.length,
    checksum: bytes.length.toString(),
    createdAt: DateTime.now().toUtc(),
  );
  final result = await _vectorRepo.reindex(artifact, bytes, _pipeline());
  if (!result.isSuccess) throw StateError('Reindex failed: ${result.error}');
  print('  ✅ Reindexed: ${result.chunksCreated} chunks (was more before)');
}

// ── 7. Delete artifact + chunks ───────────────────────────────────────────────

Future<void> _scenarioDelete() async {
  await _vectorRepo.deleteDocument(_artifactId, _tenantId, _storeId);
  final results = await _vectorRepo.search(
    'vector search',
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    artifactId: _artifactId,
  );
  if (results.isNotEmpty) throw StateError('Chunks still found after delete');
  print('  ✅ Deleted: 0 chunks remain for $_artifactId');
}
