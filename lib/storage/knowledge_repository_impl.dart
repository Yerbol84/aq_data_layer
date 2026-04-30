import 'dart:async';

import 'package:aq_schema/aq_schema.dart';

import '../repositories/knowledge_repository.dart';

import '../storage/direct_repository_impl.dart' show watchWithBuffer;

/// Default implementation of [KnowledgeRepository].
///
/// Orchestrates three backends:
/// - [_binaryStore]   — raw file bytes ([ArtifactStorage])
/// - [_metaStorage]   — document metadata ([VaultStorage])
/// - [_vectorStorage] — per-chunk embeddings ([VectorStorage])
///
/// ## Sync guarantee
/// When [save] is called with [rawText], the vectors are (re)indexed
/// atomically with the metadata write.  [vectorsUpToDate] is set to `false`
/// before indexing starts and `true` after — so callers can detect a partial
/// failure and retry via [reIndex].
///
/// ## Encryption
/// Not the responsibility of this package.  Encrypt [fileBytes] before
/// calling [save]; decrypt after [loadBytes].
final class KnowledgeRepositoryImpl<T extends KnowledgeDocument>
    implements KnowledgeRepository<T> {
  final ArtifactStorage _binaryStore;
  final VaultStorage _metaStorage;
  final VectorStorage _vectorStorage;
  final String _collection;
  final String _vectorCollection;
  final String _tenantPrefix;
  final int _vectorSize;
  final T Function(Map<String, dynamic>) _fromMap;
  final TextSplitter _splitter;
  final EmbedFn _embed;

  KnowledgeRepositoryImpl({
    required ArtifactStorage binaryStore,
    required VaultStorage metaStorage,
    required VectorStorage vectorStorage,
    required String collection,
    required int vectorSize,
    required T Function(Map<String, dynamic>) fromMap,
    required EmbedFn embed,
    TextSplitter? splitter,
    String tenantPrefix = '',
  })  : _binaryStore = binaryStore,
        _metaStorage = metaStorage,
        _vectorStorage = vectorStorage,
        _collection = collection,
        _vectorCollection = '${collection}__vectors',
        _tenantPrefix = tenantPrefix,
        _vectorSize = vectorSize,
        _fromMap = fromMap,
        _embed = embed,
        _splitter = splitter ?? FixedSizeSplitter();

  // ── Initialise ─────────────────────────────────────────────────────────────

  Future<void> _ensureCollections() async {
    await _metaStorage.ensureCollection(_collection);
    await _vectorStorage.ensureCollection(
      _vectorCollection,
      vectorSize: _vectorSize,
    );
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> save(
    T document,
    List<int> fileBytes, {
    String? rawText,
  }) async {
    await _ensureCollections();
    final key = _buildKey(document.id, document.fileName);

    // 1. Store binary
    await _binaryStore.put(key, fileBytes, contentType: document.contentType);

    // 2. Mark vectors as stale while indexing
    final metaMap = {
      ...document.toMap(),
      'storageKey': key,
      'sizeBytes': fileBytes.length,
      'checksum': _checksum(fileBytes),
      'vectorsUpToDate': false,
      'chunkCount': 0,
    };
    await _metaStorage.put(_collection, document.id, metaMap);

    // 3. Index vectors if text is provided
    if (rawText != null && rawText.isNotEmpty) {
      await _indexVectors(document.id, document.toMap(), rawText);
    }

    // 4. Mark vectors as current
    final updatedMeta = {
      ...metaMap,
      'vectorsUpToDate': rawText != null,
      'chunkCount': rawText != null ? _splitter.split(rawText).length : 0,
    };
    await _metaStorage.put(_collection, document.id, updatedMeta);
  }

  @override
  Future<void> reIndex(String documentId, String rawText) async {
    await _ensureCollections();

    // Mark stale
    final existing = await _metaStorage.get(_collection, documentId);
    if (existing == null) return;
    await _metaStorage.put(_collection, documentId, {
      ...existing,
      'vectorsUpToDate': false,
    });

    // Delete old chunks
    await _vectorStorage.deleteWhere(
      _vectorCollection,
      VaultQuery().where('docId', VaultOperator.equals, documentId),
    );

    // Re-index
    final docMeta = existing;
    await _indexVectors(documentId, docMeta, rawText);

    final chunks = _splitter.split(rawText);
    await _metaStorage.put(_collection, documentId, {
      ...existing,
      'vectorsUpToDate': true,
      'chunkCount': chunks.length,
    });
  }

  @override
  Future<void> delete(String documentId) async {
    final meta = await findById(documentId);
    if (meta != null) {
      await _binaryStore.delete(meta.storageKey);
    }
    // Delete all vector chunks for this document
    await _vectorStorage.deleteWhere(
      _vectorCollection,
      VaultQuery().where('docId', VaultOperator.equals, documentId),
    );
    await _metaStorage.delete(_collection, documentId);
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  @override
  Future<T?> findById(String documentId) async {
    final data = await _metaStorage.get(_collection, documentId);
    return data != null ? _fromMap(data) : null;
  }

  @override
  Future<List<T>> findAll({VaultQuery? query}) async {
    await _metaStorage.ensureCollection(_collection);
    final rows =
        await _metaStorage.query(_collection, query ?? const VaultQuery());
    return rows.map(_fromMap).toList();
  }

  @override
  Future<PageResult<T>> findPage(VaultQuery query) async {
    await _metaStorage.ensureCollection(_collection);
    final page = await _metaStorage.queryPage(_collection, query);
    return page.map(_fromMap);
  }

  @override
  Future<List<int>?> loadBytes(String documentId) async {
    final meta = await findById(documentId);
    if (meta == null) return null;
    return _binaryStore.get(meta.storageKey);
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  @override
  Future<List<KnowledgeSearchResult>> search(
    String query, {
    required EmbedFn embed,
    int limit = 10,
    double scoreThreshold = 0.3,
    VaultQuery? filter,
  }) async {
    final queryVector = await embed(query);

    final results = await _vectorStorage.search(
      _vectorCollection,
      queryVector,
      limit: limit,
      scoreThreshold: scoreThreshold,
      filter: filter,
    );

    final searchResults = <KnowledgeSearchResult>[];
    for (final r in results) {
      searchResults.add(KnowledgeSearchResult(
        documentId: r.payload['docId'] as String? ?? '',
        documentName: r.payload['docName'] as String? ?? '',
        chunkId: r.id,
        chunkIndex: r.payload['chunkIndex'] as int? ?? 0,
        chunkText: r.payload['text'] as String? ?? '',
        score: r.score,
      ));
    }

    return searchResults;
  }

  // ── Watch ──────────────────────────────────────────────────────────────────

  @override
  Stream<List<T>> watchAll({VaultQuery? query}) => watchWithBuffer<T>(
        _metaStorage.watchChanges(_collection),
        () => findAll(query: query),
      );

  // ── Private ────────────────────────────────────────────────────────────────

  Future<void> _indexVectors(
    String docId,
    Map<String, dynamic> docMeta,
    String rawText,
  ) async {
    final chunks = _splitter.split(rawText);
    final entries = <VectorEntry>[];

    for (final chunk in chunks) {
      final vector = await _embed(chunk.text);
      entries.add(VectorEntry(
        id: '${docId}__chunk-${chunk.index}',
        vector: vector,
        payload: {
          'docId': docId,
          'docName': docMeta['fileName'] ?? '',
          'chunkIndex': chunk.index,
          'text': chunk.text,
          'knowledgeBaseId': docMeta['knowledgeBaseId'] ?? '',
        },
      ));
    }

    await _vectorStorage.upsertAll(_vectorCollection, entries);
  }

  String _buildKey(String id, String fileName) {
    final prefix = _tenantPrefix.isEmpty ? '' : '$_tenantPrefix/';
    return '${prefix}$_collection/$id/$fileName';
  }

  String _checksum(List<int> bytes) {
    if (bytes.isEmpty) return 'empty';
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'fnv1a-${h.toRadixString(16).padLeft(8, '0')}';
  }
}
