/// S-14: Annotation-driven search — chunkId → annotation → position in doc
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'ann-tenant';
const _storeId = 'pgvector-main';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-14: Annotation-Driven Search');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('Setup', _setup);
  await run('S-14-1: search → chunkId', _s14SearchToChunk);
  await run('S-14-2: create vectorRef annotation with chunkId', _s14CreateAnnotation);
  await run('S-14-3: find annotations by artifactId', _s14FindAnnotations);
  await run('S-14-4: chunkId in annotation → span in document', _s14ChunkToSpan);
  await run('S-14-5: annotation history tracked', _s14History);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

const _artId = 'ann-doc-001';
const _docText = 'Vector search enables semantic retrieval. Embeddings capture meaning in numerical form. Cosine similarity finds related content efficiently.';

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;
late String _foundChunkId;
late ChunkSpan _foundSpan;

Future<void> _setup() async {
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenantId, useBuffer: false, authToken: 'test-admin-token');
  _embedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final registry = VectorStoreRegistryImpl();
  registry.register(VectorStoreDescriptor(id: _storeId, type: 'pgvector', embedderId: _embedder.id, vectorDim: _embedder.dimensions), RemoteVectorStorage(remote: remote));
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap);
  _repo = VectorRepositoryImpl(registry: registry, artifactRepo: artifactRepo);

  final bytes = utf8.encode(_docText);
  final artifact = StoredArtifact(id: _artId, tenantId: _tenantId, ownerId: 'ann-owner', storageKey: '$_tenantId/$_artId.txt', fileName: '$_artId.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
  await artifactRepo.save(artifact);
  await _repo.index(artifact, bytes, IndexingPipeline(id: 'ann-pipeline', storeId: _storeId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 100), embedder: _embedder, reranker: PassthroughReranker()));
  print('  ✅ Indexed $_artId');
}

Future<void> _s14SearchToChunk() async {
  final results = await _repo.search('semantic retrieval embeddings', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 1, artifactId: _artId);
  if (results.isEmpty) throw StateError('No results');
  _foundChunkId = results.first.id;
  final payload = VectorPointPayload.fromMap(results.first.payload);
  _foundSpan = payload.span;
  print('  ✅ Found chunk: $_foundChunkId span=[${_foundSpan.startOffset},${_foundSpan.endOffset}] score=${results.first.score.toStringAsFixed(4)}');
}

Future<void> _s14CreateAnnotation() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(collection: DocumentAnnotation.kCollection, fromMap: DocumentAnnotation.fromMap);
  final annotation = DocumentAnnotation(
    id: 'ann-001',
    tenantId: _tenantId,
    ownerId: 'ann-owner',
    artifactId: _artId,
    actorType: AnnotationActorType.llm,
    actorId: 'nomic-embed-text',
    type: AnnotationType.vectorRef,
    range: AnnotationRange(startOffset: _foundSpan.startOffset ?? 0, endOffset: _foundSpan.endOffset ?? 0),
    content: 'Semantically relevant chunk',
    meta: {'chunkId': _foundChunkId, 'score': 0.9, 'storeId': _storeId},
    createdAt: DateTime.now().toUtc(),
  );
  await repo.save(annotation, actorId: 'nomic-embed-text');
  print('  ✅ Created vectorRef annotation: ann-001 chunkId=$_foundChunkId');
}

Future<void> _s14FindAnnotations() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(collection: DocumentAnnotation.kCollection, fromMap: DocumentAnnotation.fromMap);
  final all = await repo.findAll(query: VaultQuery(filters: [VaultFilter('artifactId', VaultOperator.equals, _artId)]));
  if (all.isEmpty) throw StateError('No annotations found for $_artId');
  print('  ✅ Found ${all.length} annotation(s) for $_artId');
}

Future<void> _s14ChunkToSpan() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(collection: DocumentAnnotation.kCollection, fromMap: DocumentAnnotation.fromMap);
  final annotation = await repo.findById('ann-001');
  if (annotation == null) throw StateError('Annotation not found');
  final chunkId = annotation.meta['chunkId'] as String?;
  if (chunkId != _foundChunkId) throw StateError('chunkId mismatch: $chunkId != $_foundChunkId');
  // Span from annotation matches original chunk span
  if (annotation.range.startOffset != (_foundSpan.startOffset ?? 0)) {
    throw StateError('Span mismatch');
  }
  print('  ✅ Annotation → chunk link verified: $chunkId offset=[${annotation.range.startOffset},${annotation.range.endOffset}]');
}

Future<void> _s14History() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(collection: DocumentAnnotation.kCollection, fromMap: DocumentAnnotation.fromMap);
  final history = await repo.getHistory('ann-001');
  if (history.isEmpty) throw StateError('No history for ann-001');
  print('  ✅ Annotation history: ${history.length} entries');
}
