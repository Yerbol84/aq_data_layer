import 'package:aq_schema/aq_schema.dart';

import 'repositories/knowledge_repository.dart';
import 'repositories/vector_repository.dart';
import 'storage/in_memory_artifact_storage.dart';
import 'storage/in_memory_vault_storage.dart';
import 'storage/in_memory_vector_storage.dart';
import 'storage/knowledge_repository_impl.dart';
import 'storage/vector_repository_impl.dart';

/// Factory for [KnowledgeRepository] and standalone [VectorRepository].
///
/// ```dart
/// final kv = KnowledgeVault(
///   binaryStore:   LocalArtifactStorage(basePath: '/var/docs'),
///   metaStorage:   SupabaseVaultStorage(url: '...', anonKey: '...'),
///   vectorStorage: InMemoryVectorStorage(), // or QdrantVectorStorage(...)
///   tenantId:      projectId,
/// );
///
/// // Combined file+vector repository
/// final docs = kv.documents<MyDoc>(
///   collection: 'documents',
///   vectorSize: 1536,
///   fromMap: MyDoc.fromMap,
///   embed: (text) => openai.embed(text),
/// );
///
/// // Standalone vector repository (e.g. for pre-computed embeddings)
/// final vectors = kv.vectors(collection: 'embeddings', vectorSize: 768);
/// ```
final class KnowledgeVault {
  final ArtifactStorage binaryStore;
  final VaultStorage metaStorage;
  final VectorStorage vectorStorage;
  final String tenantId;

  KnowledgeVault({
    ArtifactStorage? binaryStore,
    VaultStorage? metaStorage,
    VectorStorage? vectorStorage,
    this.tenantId = 'system',
  })  : binaryStore = binaryStore ?? InMemoryArtifactStorage(),
        metaStorage = metaStorage ?? InMemoryVaultStorage(),
        vectorStorage = vectorStorage ?? InMemoryVectorStorage();

  /// Create a combined file+vector repository.
  KnowledgeRepository<T> documents<T extends KnowledgeDocument>({
    required String collection,
    required int vectorSize,
    required T Function(Map<String, dynamic>) fromMap,
    required EmbedFn embed,
    TextSplitter? splitter,
  }) {
    final col = _qualify(collection);
    return KnowledgeRepositoryImpl<T>(
      binaryStore: binaryStore,
      metaStorage: metaStorage,
      vectorStorage: vectorStorage,
      collection: col,
      vectorSize: vectorSize,
      fromMap: fromMap,
      embed: embed,
      splitter: splitter,
      tenantPrefix: tenantId == 'system' ? '' : tenantId,
    );
  }

  /// Create a standalone vector repository (no file storage).
  VectorRepository vectors({
    required String collection,
    required int vectorSize,
    String distance = 'cosine',
  }) {
    final col = _qualify(collection);
    // Ensure the collection exists in the backing vector storage.
    // Use microtask to avoid blocking the constructor.
    Future.microtask(
      () => vectorStorage.ensureCollection(col, vectorSize: vectorSize),
    );
    return VectorRepositoryImpl(storage: vectorStorage, collection: col);
  }

  Future<void> dispose() async {
    await binaryStore.dispose();
    await vectorStorage.dispose();
  }

  /// Добавляет tenant prefix к имени коллекции для изоляции.
  /// Для VectorStorage используем префикс, т.к. он не поддерживает tenantId.
  String _qualify(String c) {
    if (tenantId == 'system' || tenantId.isEmpty) return c;
    return '${tenantId}__$c';
  }
}
