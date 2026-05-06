import 'package:aq_schema/aq_schema.dart';

import 'storage/artifact_repository_impl.dart';
import 'storage/in_memory_artifact_storage.dart';
import 'storage/in_memory_vault_storage.dart';

/// Factory for [ArtifactRepository].
///
/// Uses two backends:
/// - [binaryStore] — raw file bytes ([ArtifactStorage])
/// - [metaStorage] — metadata records ([VaultStorage])
///
/// ```dart
/// final artVault = ArtifactVault(
///   binaryStore: LocalArtifactStorage(basePath: '/var/artifacts'),
///   metaStorage: SupabaseVaultStorage(url: '...', anonKey: '...'),
///   tenantId: userId,
/// );
/// final files = artVault.artifacts<MyFile>(
///   collection: 'uploads',
///   fromMap: MyFile.fromMap,
/// );
/// ```
final class ArtifactVault {
  final ArtifactStorage binaryStore;
  final VaultStorage metaStorage;
  final String tenantId;

  ArtifactVault({
    ArtifactStorage? binaryStore,
    VaultStorage? metaStorage,
    this.tenantId = 'system',
  })  : binaryStore = binaryStore ?? InMemoryArtifactStorage(),
        metaStorage = metaStorage ?? InMemoryVaultStorage();

  IArtifactRepository<T> artifacts<T extends ArtifactEntry>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
  }) {
    final col = _qualify(collection);
    return ArtifactRepositoryImpl<T>(
      binaryStore: binaryStore,
      metaStorage: metaStorage,
      collection: col,
      fromMap: fromMap,
      tenantPrefix: tenantId == 'system' ? '' : tenantId,
    );
  }

  Future<void> dispose() => binaryStore.dispose();

  /// Возвращает имя коллекции без изменений.
  /// Тенантность передаётся через tenantId в хранилище.
  String _qualify(String c) => c;
}
