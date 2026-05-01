import 'package:aq_schema/aq_schema.dart';

/// Orchestrates the full indexing pipeline:
/// extract → (transform) → chunk → embed → upsert
///
/// Also saves IndexingPipelineRecord and updates StoredArtifact.indexingStatus.
final class VectorRepositoryImpl {
  final IVectorStoreRegistry _registry;
  final DirectRepository<StoredArtifact>? _artifactRepo;
  final DirectRepository<IndexingPipelineRecord>? _pipelineRepo;

  VectorRepositoryImpl({
    required IVectorStoreRegistry registry,
    DirectRepository<StoredArtifact>? artifactRepo,
    DirectRepository<IndexingPipelineRecord>? pipelineRepo,
  })  : _registry = registry,
        _artifactRepo = artifactRepo,
        _pipelineRepo = pipelineRepo;

  Future<IndexingResult> index(
    StoredArtifact artifact,
    List<int> bytes,
    IndexingPipeline pipeline,
  ) async {
    final sw = Stopwatch()..start();

    // Mark as indexing
    await _updateStatus(artifact, IndexingStatus.indexing);

    try {
      final storage = _registry.resolve(pipeline.storeId);
      final collection = _collectionFor(artifact.tenantId);

      // 1. Extract
      final content = await pipeline.extractor.extract(
        bytes,
        artifact.contentType,
        {
          'artifactId': artifact.id,
          'tenantId': artifact.tenantId,
          'ownerId': artifact.ownerId,
        },
      );

      // 2. Transform (optional)
      final transformed = pipeline.transformer != null
          ? await pipeline.transformer!.transform(content)
          : content;

      // 3. Chunk
      final chunks = pipeline.chunker.chunk(transformed);

      // 4. Embed (batch)
      final vectors = await pipeline.embedder
          .embedBatch(chunks.map((c) => c.text).toList());

      // 5. Build VectorEntries
      final stamp = pipeline.buildStamp();
      final entries = List.generate(
        chunks.length,
        (i) => VectorEntry(
          id: '${artifact.id}__chunk-$i',
          vector: vectors[i],
          payload: VectorPointPayload(
            tenantId: artifact.tenantId,
            ownerId: artifact.ownerId,
            artifactId: artifact.id,
            storeId: pipeline.storeId,
            modality: transformed.modality,
            span: chunks[i].span,
            text: chunks[i].text,
            stamp: stamp,
          ).toMap(),
        ),
      );

      // 6. Ensure collection + upsert
      await storage.ensureCollection(
        collection,
        vectorSize: pipeline.embedder.dimensions,
      );
      await storage.upsertAll(collection, entries);

      sw.stop();
      final result = IndexingResult(
        artifactId: artifact.id,
        chunksCreated: entries.length,
        elapsed: sw.elapsed,
        stamp: stamp,
      );

      // 7. Save pipeline record (if not exists)
      await _savePipelineRecord(pipeline, stamp);

      // 8. Update artifact status → indexed
      await _updateStatusIndexed(artifact, pipeline.storeId, entries.length);

      return result;
    } catch (e) {
      sw.stop();
      await _updateStatusFailed(artifact, e.toString());
      return IndexingResult(
        artifactId: artifact.id,
        chunksCreated: 0,
        elapsed: sw.elapsed,
        stamp: pipeline.buildStamp(),
        error: e.toString(),
      );
    }
  }

  Future<IndexingResult> reindex(
    StoredArtifact artifact,
    List<int> bytes,
    IndexingPipeline pipeline,
  ) async {
    await deleteDocument(artifact.id, artifact.tenantId, pipeline.storeId);
    return index(artifact, bytes, pipeline);
  }

  Future<List<VectorSearchResult>> search(
    String query, {
    required String tenantId,
    required String storeId,
    required IEmbeddingsClient embedder,
    int topK = 10,
    String? artifactId,
    String? ownerId,
    double scoreThreshold = 0.0,
    String? sparseQuery,
    double alpha = 1.0,
    IReranker? reranker,
  }) async {
    final storage = _registry.resolve(storeId);
    final collection = _collectionFor(tenantId);
    final queryVector = await embedder.embed(query);

    final filters = <VaultFilter>[
      if (artifactId != null)
        VaultFilter('artifactId', VaultOperator.equals, artifactId),
      if (ownerId != null)
        VaultFilter('ownerId', VaultOperator.equals, ownerId),
    ];

    final results = await storage.search(
      collection,
      queryVector,
      tenantId: tenantId,
      limit: topK,
      scoreThreshold: scoreThreshold,
      filter: filters.isNotEmpty ? VaultQuery(filters: filters) : null,
      sparseQuery: sparseQuery,
      alpha: alpha,
    );

    return reranker != null ? await reranker.rerank(query, results) : results;
  }

  Future<void> deleteDocument(
    String artifactId,
    String tenantId,
    String storeId,
  ) async {
    final storage = _registry.resolve(storeId);
    await storage.deleteWhere(
      _collectionFor(tenantId),
      VaultQuery(filters: [
        VaultFilter('artifactId', VaultOperator.equals, artifactId),
      ]),
    );
  }

  // ── Private ────────────────────────────────────────────────────────────────

  String _collectionFor(String tenantId) => '${tenantId}__vectors';

  Future<void> _updateStatus(
      StoredArtifact artifact, IndexingStatus status) async {
    if (_artifactRepo == null) return;
    await _artifactRepo.save(artifact.copyWith(indexingStatus: status));
  }

  Future<void> _updateStatusIndexed(
    StoredArtifact artifact,
    String storeId,
    int chunkCount,
  ) async {
    if (_artifactRepo == null) return;
    await _artifactRepo.save(artifact.copyWith(
      indexingStatus: IndexingStatus.indexed,
      indexedStoreId: storeId,
      chunkCount: chunkCount,
      indexedAt: DateTime.now().toUtc(),
    ));
  }

  Future<void> _updateStatusFailed(
      StoredArtifact artifact, String error) async {
    if (_artifactRepo == null) return;
    await _artifactRepo.save(artifact.copyWith(
      indexingStatus: IndexingStatus.failed,
      indexingError: error,
    ));
  }

  Future<void> _savePipelineRecord(
      IndexingPipeline pipeline, PipelineStamp stamp) async {
    if (_pipelineRepo == null) return;
    final existing = await _pipelineRepo.findById(pipeline.id);
    if (existing != null) return;
    await _pipelineRepo.save(IndexingPipelineRecord(
      id: pipeline.id,
      name: pipeline.id,
      extractorId: stamp.extractorId,
      extractorVersion: stamp.extractorVersion,
      transformerId: stamp.transformerId,
      transformerVersion: stamp.transformerVersion,
      chunkerId: stamp.chunkerId,
      chunkerVersion: stamp.chunkerVersion,
      embedderId: stamp.embedderId,
      embedderVersion: stamp.embedderVersion,
      vectorDim: stamp.vectorDim,
      metric: stamp.metric,
      storeId: pipeline.storeId,
      createdAt: stamp.indexedAt,
    ));
  }
}
