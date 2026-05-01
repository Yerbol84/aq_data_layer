/// dart_vault — клиентская точка входа.
///
/// ## Разрешённый API для клиентских приложений
///
/// Клиент импортирует ТОЛЬКО этот файл:
/// ```dart
/// import 'package:dart_vault/dart_vault.dart';
/// ```
///
/// ### Что доступно клиенту:
/// - [Vault] — фабрика и синглтон. Используй [Vault.connect] и [Vault.instance].
/// - [DirectRepository] — простой CRUD без истории.
/// - [VersionedRepository] — версионирование с ветками и ACL.
/// - [LoggedRepository] — CRUD с полной историей изменений.
/// - [ArtifactVault] — работа с файлами (binary + metadata).
/// - [KnowledgeVault] — работа с документами и векторным поиском.
/// - [VaultException] и подклассы — для обработки ошибок.
///
/// ### Что ЗАПРЕЩЕНО клиенту:
/// - Не создавай репозитории напрямую (`DirectRepositoryImpl` и т.д.)
/// - Не импортируй `package:dart_vault/server.dart`
/// - Не создавай хранилища (`VaultStorage`, `PostgresVaultStorage` и т.д.)
/// - Не используй security компоненты напрямую (rate limiting, audit logging)
/// - Не создавай свои репозитории-обёртки с логикой — только в целевых пакетах
///   и только как тонкие геттеры без бизнес-логики
///
/// ### Единственный способ начать работу:
///
/// **Рекомендуется (aq_schema protocol):**
/// ```dart
/// // Один раз при запуске приложения:
/// await IDataLayer.initialize(endpoint: 'https://your-data-service.example.com');
///
/// // Везде в коде:
/// final repo = IDataLayer.instance.versioned<Blueprint>(
///   collection: 'blueprints',
///   fromMap: Blueprint.fromMap,
/// );
/// final node = await repo.createEntity(blueprint);
/// ```
///
/// **Альтернатива (dart_vault specific, backward compatibility):**
/// ```dart
/// await Vault.connect('https://your-data-service.example.com');
/// final repo = Vault.instance.versioned<Blueprint>(...);
/// ```
library dart_vault;

import 'package:aq_schema/aq_schema.dart';

import 'client/data_layer_impl.dart';

// ── Единственная точка входа для клиента ──────────────────────────────────
export 'client/vault.dart' show Vault;
export 'client/data_layer_impl.dart' show DataLayerImpl;
export 'client/remote/remote_vault_storage.dart' show RemoteVaultStorage;
export 'client/remote/remote_artifact_storage.dart' show RemoteArtifactStorage;
export 'client/remote/remote_vector_storage.dart' show RemoteVectorStorage;

// ── Репозитории из aq_schema (source of truth) ────────────────────────────
export 'package:aq_schema/aq_schema.dart'
    show
        IDataLayer,
        DirectRepository,
        VersionedRepository,
        LoggedRepository,
        IAuthContext;

// ── Специализированные репозитории (dart_vault specific) ──────────────────
export 'repositories/artifact_repository.dart';
export 'repositories/vector_repository.dart';
export 'repositories/knowledge_repository.dart';

// ── Vector pipeline implementations ───────────────────────────────────────
export 'vector/mock_embeddings_client.dart';
export 'vector/mock_chunker.dart';
export 'vector/sentence_chunker.dart';
export 'vector/plain_text_extractor.dart';
export 'vector/passthrough_reranker.dart';
export 'vector/ollama_reranker.dart';

export 'vector/vector_store_registry_impl.dart';
export 'vector/ollama_embeddings_client.dart';
export 'storage/vector_repository_impl.dart';
export 'storage/in_memory_vector_storage.dart';

// ── Специализированные Vault фабрики ──────────────────────────────────────
export 'artifact_vault.dart' show ArtifactVault;
export 'knowledge_vault.dart' show KnowledgeVault;

// ── Исключения ────────────────────────────────────────────────────────────
export 'exceptions/vault_exceptions.dart';

// ══════════════════════════════════════════════════════════════════════════
// Helper function for convenient initialization
// ══════════════════════════════════════════════════════════════════════════

/// Convenience function to create and register DataLayerImpl.
///
/// This is a helper that combines:
/// 1. Creating DataLayerImpl with connection details
/// 2. Registering it with IDataLayer protocol
///
/// ```dart
/// import 'package:dart_vault/dart_vault.dart';
///
/// void main() async {
///   await initializeDataLayer(
///     endpoint: 'http://localhost:8765',
///     useBuffer: false,
///   );
///
///   // Now use IDataLayer.instance everywhere
///   final repo = IDataLayer.instance.direct<Project>(...);
/// }
/// ```
Future<void> initializeDataLayer({
  required String endpoint,
  String tenantId = 'system',
  bool useBuffer = true,
  String? authToken,
  String? key, // null = default instance, non-null = named instance
}) async {
  final token = authToken ?? await IAuthContext.instance?.currentToken;
  final resolvedTenantId =
      tenantId != 'system' ? tenantId : (await IAuthContext.instance?.currentTenantId ?? tenantId);
  final impl = await DataLayerImpl.connect(
    endpoint: endpoint,
    tenantId: resolvedTenantId,
    useBuffer: useBuffer,
    authToken: token,
  );
  IDataLayer.register(impl, key: key);
}

// Register initializer so IDataLayer.initialize() works when dart_vault is imported.
// ignore: unused_element
final _dartVaultInit = () {
  IDataLayer.registerInitializer(({
    required String endpoint,
    String tenantId = 'system',
    bool useBuffer = true,
  }) =>
      initializeDataLayer(
        endpoint: endpoint,
        tenantId: tenantId,
        useBuffer: useBuffer,
      ));
}();

