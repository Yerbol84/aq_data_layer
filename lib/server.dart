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
export 'storage/direct_repository_impl.dart';
export 'storage/versioned_repository_impl.dart';
export 'storage/logged_repository_impl.dart';
export 'storage/artifact_repository_impl.dart';
export 'storage/vector_repository_impl.dart';
export 'storage/knowledge_repository_impl.dart';
export 'storage/in_memory_artifact_storage.dart';
export 'storage/local_artifact_storage.dart';
export 'storage/in_memory_vector_storage.dart';
export 'storage/versioned_storage_contract.dart';

// ── Remote storage (для клиент-серверной архитектуры) ─────────────────────
export 'client/remote/remote_vault_storage.dart';
export 'client/remote/remote_vault_schema.dart';
export 'client/remote/vault_client.dart';
export 'client/remote/remote_logged_repository.dart';

// ── Security (ТОЛЬКО на сервере) ──────────────────────────────────────────
export 'security/rate_limit_store.dart';
export 'security/in_memory_rate_limit_store.dart';
export 'security/rate_limit_config.dart';
export 'security/vault_rate_limiter.dart';
export 'security/dos_config.dart';
export 'security/dos_protection.dart';
export 'security/secrets_manager.dart';
export 'security/secrets_cache.dart';
export 'security/in_memory_secrets_manager.dart';
export 'security/vault_http_client.dart';
export 'security/vault_secrets_manager.dart';
export 'security/aws_secrets_manager.dart';
export 'security/credential_rotation_service.dart';
export 'security/secrets_migration.dart';
export 'security/audit_event.dart';
export 'security/audit_logger.dart';
export 'security/in_memory_audit_logger.dart';
export 'security/postgres_audit_logger.dart';
export 'security/audit_retention.dart';
export 'security/audit_report.dart';
export 'security/audit_analyzer.dart';
export 'security/input_sanitizer.dart';
export 'security/query_validator.dart';
export 'security/safe_query_builder.dart';
export 'security/sql_safety_validator.dart';
