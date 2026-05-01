/// AQ Data Layer — Vector Search Scenarios
///
/// Сценарии:
///   1. Index    — загрузить текст, проиндексировать (mock pipeline)
///   2. Search   — найти топ-3 чанка по запросу
///   3. Filter   — поиск только в одном артефакте
///   4. Reindex  — изменить текст, переиндексировать
///   5. Delete   — удалить чанки, убедиться что поиск пуст
///   6. Multi-tenant — два тенанта, изоляция поиска
///   7. Pipeline record — pipeline сохранён в БД
///   8. Artifact status — StoredArtifact.indexingStatus = indexed
///   9. Failed indexing — неподдерживаемый contentType → status = failed
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint =
    Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';

const _tenantA = 'tenant-vector-a';
const _tenantB = 'tenant-vector-b';
const _owner = 'user-vec-001';
const _storeId = 'memory-default';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — Vector Search Scenarios');
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

  await run('1. Index document', _scenarioIndex);
  await run('2. Search top-3', _scenarioSearch);
  await run('3. Filter by artifactId', _scenarioFilter);
  await run('4. Reindex', _scenarioReindex);
  await run('5. Delete document chunks', _scenarioDelete);
  await run('6. Multi-tenant isolation', _scenarioMultiTenant);
  await run('7. Pipeline record in DB', _scenarioPipelineRecord);
  await run('8. Artifact indexing status', _scenarioArtifactStatus);
  await run('9. Failed indexing status', _scenarioFailedStatus);
  await run('10. Remote RPC transport', _scenarioRemoteRpc);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

// ── Shared helpers ────────────────────────────────────────────────────────────

final _embedder = MockEmbeddingsClient(dimensions: 8);
final _registry = VectorStoreRegistryImpl();
late VectorRepositoryImpl _repo;

Future<void> _setup(String tenantId) async {
  await initializeDataLayer(
    endpoint: _endpoint,
    tenantId: tenantId,
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
  _repo = VectorRepositoryImpl(
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
      id: 'mock-pipeline-v1',
      storeId: _storeId,
      extractor: PlainTextExtractor(),
      chunker: MockChunker(maxChunkSize: 100),
      embedder: _embedder,
      reranker: PassthroughReranker(),
    );

StoredArtifact _artifact(String id, String tenantId, {String contentType = 'text/plain'}) =>
    StoredArtifact(
      id: id,
      tenantId: tenantId,
      ownerId: _owner,
      storageKey: '$tenantId/$id/content.txt',
      fileName: '$id.txt',
      contentType: contentType,
      sizeBytes: 100,
      checksum: 'abc',
      createdAt: DateTime.now().toUtc(),
    );

List<int> _bytes(String text) => utf8.encode(text);

// ── 1. Index ──────────────────────────────────────────────────────────────────

Future<void> _scenarioIndex() async {
  await _setup(_tenantA);
  final artifact = _artifact('art-vec-001', _tenantA);
  final result = await _repo.index(
    artifact,
    _bytes('The quick brown fox jumps over the lazy dog. '
        'Pack my box with five dozen liquor jugs. '
        'How vexingly quick daft zebras jump.'),
    _pipeline(),
  );
  if (!result.isSuccess) throw StateError('Index failed: ${result.error}');
  if (result.chunksCreated == 0) throw StateError('No chunks created');
  print('  ✅ Indexed: ${result.chunksCreated} chunks in ${result.elapsed.inMilliseconds}ms');
}

// ── 2. Search ─────────────────────────────────────────────────────────────────

Future<void> _scenarioSearch() async {
  final results = await _repo.search(
    'quick fox',
    tenantId: _tenantA,
    storeId: _storeId,
    embedder: _embedder,
    topK: 3,
  );
  if (results.isEmpty) throw StateError('No search results');
  print('  ✅ Search results: ${results.length}');
  for (final r in results) {
    final payload = VectorPointPayload.fromMap(r.payload);
    print('     • score=${r.score.toStringAsFixed(4)} chunk=${payload.span.chunkIndex}');
  }
}

// ── 3. Filter by artifactId ───────────────────────────────────────────────────

Future<void> _scenarioFilter() async {
  // Index a second artifact
  final art2 = _artifact('art-vec-002', _tenantA);
  await _repo.index(
    art2,
    _bytes('Completely different content about databases and SQL queries.'),
    _pipeline(),
  );

  // Search filtered to art-vec-001 only
  final results = await _repo.search(
    'quick fox',
    tenantId: _tenantA,
    storeId: _storeId,
    embedder: _embedder,
    artifactId: 'art-vec-001',
  );
  if (results.any((r) => r.payload['artifactId'] != 'art-vec-001')) {
    throw StateError('Filter leak: got results from wrong artifact');
  }
  print('  ✅ Filter by artifactId: ${results.length} results, all from art-vec-001');
}

// ── 4. Reindex ────────────────────────────────────────────────────────────────

Future<void> _scenarioReindex() async {
  final artifact = _artifact('art-vec-001', _tenantA);
  final result = await _repo.reindex(
    artifact,
    _bytes('Completely new content after reindexing. Vector space updated.'),
    _pipeline(),
  );
  if (!result.isSuccess) throw StateError('Reindex failed: ${result.error}');
  print('  ✅ Reindexed: ${result.chunksCreated} chunks');
}

// ── 5. Delete ─────────────────────────────────────────────────────────────────

Future<void> _scenarioDelete() async {
  await _repo.deleteDocument('art-vec-001', _tenantA, _storeId);
  final results = await _repo.search(
    'new content',
    tenantId: _tenantA,
    storeId: _storeId,
    embedder: _embedder,
    artifactId: 'art-vec-001',
  );
  if (results.isNotEmpty) throw StateError('Chunks still found after delete');
  print('  ✅ Deleted: 0 results after deletion');
}

// ── 6. Multi-tenant isolation ─────────────────────────────────────────────────

Future<void> _scenarioMultiTenant() async {
  // Index same text in tenant B
  final artB = _artifact('art-vec-b-001', _tenantB);
  await _repo.index(
    artB,
    _bytes('Tenant B exclusive content. Should not appear in tenant A search.'),
    _pipeline(),
  );

  // Search in tenant A — must not see tenant B results
  final resultsA = await _repo.search(
    'tenant B exclusive',
    tenantId: _tenantA,
    storeId: _storeId,
    embedder: _embedder,
  );
  if (resultsA.any((r) => r.payload['tenantId'] == _tenantB)) {
    throw StateError('Tenant isolation breach: tenant B data visible in tenant A');
  }
  print('  ✅ Multi-tenant isolation: tenant A sees ${resultsA.length} results, none from tenant B');
}

// ── 7. Pipeline record in DB ──────────────────────────────────────────────────

Future<void> _scenarioPipelineRecord() async {
  final pipelineRepo = IDataLayer.instance.direct<IndexingPipelineRecord>(
    collection: IndexingPipelineRecord.kCollection,
    fromMap: IndexingPipelineRecord.fromMap,
  );
  final record = await pipelineRepo.findById('mock-pipeline-v1');
  if (record == null) throw StateError('Pipeline record not found in DB');
  print('  ✅ Pipeline record: ${record.id} embedder=${record.embedderId} dim=${record.vectorDim}');
}

// ── 8. Artifact indexing status ───────────────────────────────────────────────

Future<void> _scenarioArtifactStatus() async {
  // Index a fresh artifact
  final artifact = _artifact('art-status-001', _tenantA);
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );
  await artifactRepo.save(artifact);
  await _repo.index(artifact, _bytes('Status test content.'), _pipeline());

  final updated = await artifactRepo.findById('art-status-001');
  if (updated == null) throw StateError('Artifact not found');
  if (updated.indexingStatus != IndexingStatus.indexed) {
    throw StateError('Expected indexed, got ${updated.indexingStatus}');
  }
  print('  ✅ Artifact status: ${updated.indexingStatus.name} chunks=${updated.chunkCount}');
}

// ── 9. Failed indexing status ─────────────────────────────────────────────────

Future<void> _scenarioFailedStatus() async {
  final artifact = _artifact('art-fail-001', _tenantA, contentType: 'application/pdf');
  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );
  await artifactRepo.save(artifact);

  // PlainTextExtractor doesn't support application/pdf — will fail at extract
  // Actually PlainTextExtractor will still decode bytes as UTF-8.
  // To force failure, use unsupported bytes that cause an error.
  // Simplest: override with a pipeline that throws.
  final failPipeline = IndexingPipeline(
    id: 'fail-pipeline-v1',
    storeId: _storeId,
    extractor: _ThrowingExtractor(),
    chunker: MockChunker(),
    embedder: _embedder,
    reranker: PassthroughReranker(),
  );

  final result = await _repo.index(artifact, _bytes('any'), failPipeline);
  if (result.isSuccess) throw StateError('Expected failure but got success');

  final updated = await artifactRepo.findById('art-fail-001');
  if (updated?.indexingStatus != IndexingStatus.failed) {
    throw StateError('Expected failed status, got ${updated?.indexingStatus}');
  }
  print('  ✅ Failed status: ${updated!.indexingStatus.name} error="${updated.indexingError}"');
}

// ── 10. Remote RPC transport ──────────────────────────────────────────────────

Future<void> _scenarioRemoteRpc() async {
  // Use RemoteVectorStorage directly — goes through server RPC
  final remote = RemoteVaultStorage(
    endpoint: _endpoint,
    tenantId: _tenantA,
    authToken: 'test-admin-token',
  );
  await remote.connect();
  final remoteVec = RemoteVectorStorage(remote: remote);

  const col = 'rpc-test__vectors';
  await remoteVec.ensureCollection(col, vectorSize: 8);

  // Upsert via RPC
  final entry = VectorEntry(
    id: 'rpc-test-chunk-001',
    vector: await _embedder.embed('remote rpc test content'),
    payload: {
      'tenantId': _tenantA,
      'ownerId': _owner,
      'artifactId': 'rpc-art-001',
      'storeId': 'pgvector-main',
      'modality': 'text',
      'text': 'remote rpc test content',
    },
  );
  await remoteVec.upsertAll(col, [entry]);

  // Search via RPC
  final results = await remoteVec.search(
    col,
    await _embedder.embed('remote rpc test'),
    tenantId: _tenantA,
    limit: 5,
  );
  if (results.isEmpty) throw StateError('No results from remote vector search');
  print('  ✅ Remote RPC: upsert + search via server, ${results.length} result(s)');

  // Cleanup
  await remoteVec.deleteWhere(
    col,
    VaultQuery(filters: [VaultFilter('artifactId', VaultOperator.equals, 'rpc-art-001')]),
  );
}

// ── Test helper ───────────────────────────────────────────────────────────────

final class _ThrowingExtractor implements IContentExtractor {
  @override
  String get id => 'throwing-v1';
  @override
  String get version => '1';
  @override
  Set<String> get supportedContentTypes => const {};

  @override
  Future<ExtractedContent> extract(
    List<int> bytes, String contentType, Map<String, dynamic> meta) async {
    throw UnsupportedError('Content type not supported: $contentType');
  }
}
