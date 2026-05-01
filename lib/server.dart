// lib/server.dart
/// dart_vault — Серверная библиотека для работы с данными.
///
/// Этот файл экспортирует серверную часть пакета (Storage + Deploy + Security).
/// Для клиентской части используйте `package:dart_vault/dart_vault.dart`.
///
/// ## Использование на сервере:
///
/// ```dart
/// import 'package:dart_vault/server.dart';
/// import 'package:dart_vault/security_protocol.dart';
/// import 'package:aq_schema/aq_schema.dart';
///
/// void main() async {
///   final pool = await Pool.connect(...);
///
///   // Создать security service (опционально)
///   final securityService = MySecurityService(); // Ваша реализация
///
///   // Создать хранилище с security
///   final storage = PostgresVaultStorage(
///     pool: pool,
///     tenantId: 'system',
///     securityProtocol: securityService, // Опционально
///   );
///
///   // Создать registry и зарегистрировать домены
///   final registry = VaultRegistry(
///     storageFactory: (tenantId) => PostgresVaultStorage(
///       pool: pool,
///       tenantId: tenantId,
///       securityProtocol: securityService,
///     ),
///     deployer: PostgresSchemaDeployer(pool: pool),
///   );
///
///   for (final domain in AqDomains.all) {
///     registry.register(DomainRegistration(
///       collection: domain.collection,
///       mode: domain.kind.toStorageMode(),
///       fromMap: domain.fromMap,
///     ));
///   }
///
///   await registry.deploy(); // Создать таблицы
/// }
/// ```
library dart_vault.server;

// ── Клиентский API (нужен серверу для создания репозиториев) ──────────────
export 'dart_vault.dart';

// ── Security Protocol (интерфейс из aq_schema) ───────────────────────────
// Реализация живёт в отдельном пакете (aq_security)
// Интерфейс: IVaultSecurityProtocol из aq_schema

// ── Deploy (регистрация доменов, схема) ───────────────────────────────────
export 'deploy/domain_registration.dart';
export 'deploy/vault_registry.dart';
export 'deploy/schema_deployer.dart';

// ── Storage реализации ────────────────────────────────────────────────────
export 'storage/in_memory_vault_storage.dart';
export 'storage/local_buffer_vault_storage.dart';
export 'storage/supabase_vault_storage.dart';
export 'storage/postgres/postgres_vault_storage.dart';
export 'storage/postgres/postgres_schema_deployer.dart';
export 'storage/postgres/postgres_versioned_repository.dart';
export 'storage/postgres/pg_vector_storage.dart';
export 'storage/sql/i_sql_query_compiler.dart';
export 'storage/sql/postgres_query_compiler.dart';
export 'storage/sql/sql_vault_storage.dart';
export 'storage/direct_repository_impl.dart';
export 'storage/versioned_repository_impl.dart';
export 'storage/logged_repository_impl.dart';
export 'storage/artifact_repository_impl.dart';
export 'storage/vector_repository_impl.dart';
export 'storage/knowledge_repository_impl.dart';
export 'storage/in_memory_artifact_storage.dart';
export 'storage/local_artifact_storage.dart';
export 'storage/in_memory_vector_storage.dart';
export 'vector/vector_store_registry_impl.dart';
export 'vector/mock_embeddings_client.dart';
export 'vector/mock_chunker.dart';
export 'vector/sentence_chunker.dart';
export 'vector/plain_text_extractor.dart';
export 'vector/passthrough_reranker.dart';
export 'vector/ollama_reranker.dart';
export 'vector/ollama_embeddings_client.dart';

// ── Remote storage (для клиент-серверной архитектуры) ─────────────────────
export 'client/remote/remote_vault_storage.dart';
export 'client/remote/remote_vault_schema.dart';
export 'client/remote/vault_client.dart';
export 'client/remote/remote_logged_repository.dart';

// ── Security (ТОЛЬКО на сервере) ──────────────────────────────────────────
// Security логика делегируется через IVaultSecurityProtocol из aq_schema.
// Реализация живёт в пакете aq_security.
// Файлы в lib/security/ — временный артефакт, будут перенесены в aq_security.
// Не экспортируем их здесь — они не являются частью публичного API data layer.
