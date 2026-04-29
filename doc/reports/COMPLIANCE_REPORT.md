# Отчёт о соответствии пакета dart_vault_package архитектурным принципам

**Дата:** 2026-04-10
**Пакет:** `dart_vault_package`
**Базовый документ:** `../aq_schema/PACKAGE_ARCHITECTURE.md` v2.0
**Общая оценка:** ⚠️ **70% соответствие** (требуется рефакторинг)

---

## Исполнительное резюме

Пакет `dart_vault_package` имеет **хорошую основу**, но содержит **3 критических отклонения** от архитектурных принципов:

1. ❌ Смешанный экспорт клиента и сервера в главном файле
2. ❌ Множественные barrel-файлы нарушают принцип единой точки входа
3. ❌ Security и Storage компоненты доступны клиенту

Эти отклонения нарушают фундаментальный принцип **"тонкого клиента"** и требуют рефакторинга.

---

## ❌ Отклонение #1: Смешанный экспорт в главном файле

### Требование из документа (Раздел 2.2)

> **КРИТИЧЕСКИ ВАЖНО:**
>
> Главный файл пакета (`lib/my_package.dart`) экспортирует **ТОЛЬКО клиентскую часть**:
> ```dart
> export 'client/my_service_client.dart';
> export 'client/my_repository.dart';
> // НЕ экспортируем server/ и storage/
> ```

### Текущая реализация

**Файл `lib/dart_vault_package.dart`:**
```dart
// Core exports
export 'client/vault.dart';                    // ✅ Клиент
export 'repositories/repository.dart';         // ✅ Клиент

// Storage exports
export 'storage/vault_storage.dart';           // ❌ СЕРВЕРНЫЙ компонент
export 'storage/local_buffer_vault_storage.dart'; // ❌ СЕРВЕРНЫЙ компонент

// Security exports
export 'security/rate_limit_store.dart';           // ❌ СЕРВЕРНЫЙ компонент
export 'security/in_memory_rate_limit_store.dart'; // ❌ СЕРВЕРНЫЙ компонент
export 'security/vault_rate_limiter.dart';         // ❌ СЕРВЕРНЫЙ компонент
export 'security/dos_protection.dart';             // ❌ СЕРВЕРНЫЙ компонент
export 'security/secrets_manager.dart';            // ❌ СЕРВЕРНЫЙ компонент
export 'security/audit_logger.dart';               // ❌ СЕРВЕРНЫЙ компонент
export 'security/postgres_audit_logger.dart';      // ❌ СЕРВЕРНЫЙ компонент

// Deploy exports
export 'deploy/vault_registry.dart';           // ❌ СЕРВЕРНЫЙ компонент
```

### Проблема

**Должно быть:**
- Клиент видит только `Vault`, `Repository`, интерфейсы
- Клиент НЕ знает о `VaultStorage`, `PostgresAuditLogger`, `VaultRegistry`

**У вас:**
- Клиент получает доступ к серверным компонентам
- Нарушается принцип "тонкого клиента"

### Цитата из документа (Раздел 1.2, постулат 3)

> **Клиент максимально тонкий**
> - Клиентское приложение НЕ пишет ни строчки бизнес-логики
> - Клиент просто подключает пакет и получает готовый сервис
> - Вся логика реализована на уровне пакета (и на клиенте, и на сервере)

### Цитата из документа (Раздел 5.2.5)

> **Безопасность**
> - Storage живёт только на сервере
> - Клиент не знает о способах хранения
> - Все операции идут через контролируемый API

---

## ❌ Отклонение #2: Множественные barrel-файлы

### Требование из документа (Раздел 2.2)

> Главный файл пакета (`lib/my_package.dart`) экспортирует **ТОЛЬКО клиентскую часть**

Подразумевается **один главный файл** для клиента, **один файл** для сервера.

### Текущая реализация

```
lib/
├── dart_vault_package.dart    ← главный (но смешанный)
├── dart_vault.dart            ← альтернативный клиентский
├── artifact_vault.dart        ← специализированный
├── knowledge_vault.dart       ← специализированный
└── server.dart                ← серверный
```

### Проблема

**Должно быть:**
- Один файл для клиента: `dart_vault_package.dart`
- Один файл для сервера: `server.dart`

**У вас:**
- 4 клиентских файла (`dart_vault_package.dart`, `dart_vault.dart`, `artifact_vault.dart`, `knowledge_vault.dart`)
- Непонятно какой файл импортировать
- Нарушается принцип единой точки входа

### Цитата из документа (Раздел 1.3)

> Пакет `aq_schema` экспортирует не отдельные файлы, а **тематические наборы**. Потребитель импортирует ровно тот набор, который ему нужен.

Для обычных пакетов (не aq_schema) это означает **один набор** = **один файл**.

---

## ❌ Отклонение #3: Security компоненты в клиенте

### Требование из документа (Раздел 2.2, правило 3)

> **Storage реализации живут ТОЛЬКО на сервере**:
> - Клиент получает только Repository
> - Storage остаётся на сервере и не передаётся клиенту

### Текущая реализация

**Файл `lib/dart_vault_package.dart` экспортирует:**
```dart
// Security exports
export 'security/rate_limit_store.dart';           // ❌ Серверный компонент
export 'security/in_memory_rate_limit_store.dart'; // ❌ Серверный компонент
export 'security/vault_rate_limiter.dart';         // ❌ Серверный компонент
export 'security/dos_protection.dart';             // ❌ Серверный компонент
export 'security/secrets_manager.dart';            // ❌ Серверный компонент
export 'security/vault_secrets_manager.dart';      // ❌ Серверный компонент
export 'security/aws_secrets_manager.dart';        // ❌ Серверный компонент
export 'security/credential_rotation_service.dart'; // ❌ Серверный компонент
export 'security/audit_logger.dart';               // ❌ Серверный компонент
export 'security/postgres_audit_logger.dart';      // ❌ Серверный компонент
export 'security/audit_report.dart';               // ❌ Серверный компонент
```

### Проблема

**Должно быть:**
- Клиент не знает о `PostgresAuditLogger`, `AWSSecretsManager`, `DoSProtection`
- Эти компоненты живут только на сервере

**У вас:**
- Клиент может создать `PostgresAuditLogger` напрямую
- Клиент может обойти rate limiting
- Нарушается безопасность

### Цитата из документа (Раздел 4.1)

> ```dart
> // В клиентском приложении
> import 'package:dart_vault/dart_vault.dart';
>
> // Клиент делает handshake и получает готовый репозиторий
> await Vault.connect('http://localhost:8765');
>
> final workflows = Vault.instance.versioned<WorkflowGraph>(
>   collection: WorkflowGraph.kCollection,
>   fromMap: WorkflowGraph.fromMap,
> );
>
> // Всё! Клиент не знает о PostgreSQL, Supabase, или способах хранения
> await workflows.createEntity(myWorkflow);
> ```

Клиент должен видеть **только** `Vault` и `Repository`. Всё остальное — на сервере.

---

## ✅ Соответствие архитектурным принципам

### 1. Наличие server.dart (Раздел 2.2)

**Требование:**
> Серверная часть экспортируется через **отдельный файл** (`lib/server.dart`)

**Текущая реализация (`lib/server.dart`):**
```dart
// ── Deploy (регистрация доменов, схема) ───────────────────────────────────
export 'deploy/domain_registration.dart';
export 'deploy/vault_registry.dart';
export 'deploy/schema_deployer.dart';

// ── Storage реализации ────────────────────────────────────────────────────
export 'storage/in_memory_vault_storage.dart';
export 'storage/postgres/postgres_vault_storage.dart';
export 'storage/postgres/postgres_schema_deployer.dart';
// ...
```

**Статус:** ✅ **СООТВЕТСТВУЕТ** — серверный файл есть и правильно структурирован

---

### 2. Handshake протокол (Раздел 4.1)

**Требование:**
> 1. **Клиент подключается**: `Vault.connect('http://localhost:8765')`
> 2. **Сервер отвечает** списком доступных коллекций
> 3. **Клиент получает полный репозиторий** — готов к работе!

**Текущая реализация:**
- ✅ Handshake реализован через `Vault.connect()`
- ✅ Сервер возвращает список коллекций
- ✅ Клиент получает готовые репозитории

**Статус:** ✅ **СООТВЕТСТВУЕТ**

---

### 3. Зависимость от aq_schema (Раздел 1.2)

**Требование:**
> Все домены, которые регистрируются в пакетах, должны быть определены в `aq_schema`

**Текущая реализация:**
- ✅ Использует интерфейсы из `aq_schema` (`Storable`, `Versionable`)
- ✅ Регистрирует домены из `aq_schema` (`WorkflowGraph`, `InstructionGraph`)

**Статус:** ✅ **СООТВЕТСТВУЕТ**

---

## 💡 Рекомендации по исправлению

### Рекомендация #1: Реорганизовать barrel-файлы

**Идея:**
Оставить **только два файла**:
- `lib/dart_vault_package.dart` — клиентский экспорт
- `lib/server.dart` — серверный экспорт

**Абстрактный подход:**

1. **Удалить дублирующие файлы:**
   - Удалить `lib/dart_vault.dart` (дублирует `dart_vault_package.dart`)
   - Удалить `lib/artifact_vault.dart` (включить в главный файл)
   - Удалить `lib/knowledge_vault.dart` (включить в главный файл)

2. **Переписать `lib/dart_vault_package.dart`:**
   - Экспортировать ТОЛЬКО клиентские компоненты
   - Убрать все `storage/`, `security/`, `deploy/` экспорты

3. **Переместить серверные экспорты в `lib/server.dart`:**
   - Все `storage/` компоненты
   - Все `security/` компоненты
   - Все `deploy/` компоненты

**Идеальный пример:**

```dart
// lib/dart_vault_package.dart — ТОЛЬКО клиент
library dart_vault_package;

// Core client
export 'client/vault.dart';
export 'client/remote/remote_vault_storage.dart';  // Клиентский транспорт

// Repositories (интерфейсы)
export 'repositories/repository.dart';
export 'repositories/versioned_repository.dart';
export 'repositories/logged_repository.dart';
export 'repositories/artifact_repository.dart';
export 'repositories/vector_repository.dart';
export 'repositories/knowledge_repository.dart';

// Exceptions
export 'exceptions/vault_exceptions.dart';

// Всё! Клиент не видит storage, security, deploy
```

```dart
// lib/server.dart — клиент + сервер
library dart_vault_package.server;

export 'dart_vault_package.dart';  // ✅ Включить клиента

// Deploy
export 'deploy/domain_registration.dart';
export 'deploy/vault_registry.dart';
export 'deploy/schema_deployer.dart';

// Storage реализации
export 'storage/in_memory_vault_storage.dart';
export 'storage/postgres/postgres_vault_storage.dart';
export 'storage/supabase_vault_storage.dart';
// ...

// Security (ТОЛЬКО на сервере)
export 'security/rate_limit_store.dart';
export 'security/vault_rate_limiter.dart';
export 'security/dos_protection.dart';
export 'security/secrets_manager.dart';
export 'security/audit_logger.dart';
export 'security/postgres_audit_logger.dart';
// ...
```

**Преимущества:**
- Клиент не может случайно использовать серверные компоненты
- Понятно что импортировать: `dart_vault_package` для клиента, `dart_vault_package/server.dart` для сервера
- Соответствует принципу единой точки входа

---

### Рекомендация #2: Изолировать security на сервере

**Идея:**
Security компоненты должны быть **недоступны** клиенту. Клиент работает через `Vault` и `Repository`, которые внутри используют security, но не экспортируют его.

**Абстрактный подход:**

1. **Убрать все security экспорты из клиентского файла**
2. **Переместить security в `lib/server.dart`**
3. **Клиент использует security через Vault:**
   - Rate limiting применяется автоматически на сервере
   - Audit logging происходит на сервере
   - Клиент не знает о существовании этих компонентов

**Идеальный пример использования:**

```dart
// Клиентское приложение
import 'package:dart_vault_package/dart_vault_package.dart';

// Клиент НЕ МОЖЕТ создать PostgresAuditLogger
// Клиент НЕ МОЖЕТ обойти rate limiting
// Клиент НЕ МОЖЕТ получить доступ к secrets manager

// Клиент работает только через Vault
await Vault.connect('http://localhost:8765');
final repo = Vault.instance.versioned<WorkflowGraph>(...);
await repo.createEntity(workflow);  // Rate limiting применяется автоматически
```

```dart
// Серверное приложение
import 'package:dart_vault_package/server.dart';

// Сервер настраивает security
final storage = PostgresVaultStorage(
  pool: pg,
  tenantId: tenantId,
  rateLimiter: VaultRateLimiter(store: InMemoryRateLimitStore()),
  auditLogger: PostgresAuditLogger(pool: pg),
  secretsManager: VaultSecretsManager(vault: vault),
);

// Сервер регистрирует домены
final registry = VaultRegistry(storageFactory: (_) => storage);
```

**Преимущества:**
- Безопасность на уровне архитектуры
- Клиент не может обойти защиту
- Соответствует принципу "тонкого клиента"

---

### Рекомендация #3: Добавить типизированные клиенты

**Требование из документа (Раздел 3.2.2):**

> **Типизированные клиенты:**
>
> | Клиент | Интерфейс | Получает |
> |--------|-----------|---------|
> | Приложение/UI | `IAQVaultUserClient` | CRUD своих объектов в рамках projectId |
> | Движок | `IAQVaultEngineClient` | read-only загрузка графов, запись run-state |
> | Воркер | `IAQVaultWorkerClient` | = EngineClient, инициализируется через RemoteVaultStorage |
> | Администратор | `IAQVaultAdminClient` | + cross-tenant query, миграции |

**Идея:**
Разные потребители получают разные API. UI приложение не может делать cross-tenant query. Воркер не может удалять данные других проектов.

**Абстрактный подход:**

1. **Определить интерфейсы в `aq_schema/clients.dart`:**
   ```dart
   abstract interface class IAQVaultUserClient {
     static IAQVaultUserClient get instance => AQPlatform.resolve();

     VersionedRepository<T> versioned<T>({...});
     DirectRepository<T> direct<T>({...});
     // CRUD только в рамках своего projectId
   }

   abstract interface class IAQVaultEngineClient {
     static IAQVaultEngineClient get instance => AQPlatform.resolve();

     Future<T> loadGraph<T>(String blueprintId);  // read-only
     Future<void> saveRunState(String runId, Map<String, dynamic> state);
     // НЕТ delete, НЕТ cross-tenant
   }

   abstract interface class IAQVaultAdminClient {
     static IAQVaultAdminClient get instance => AQPlatform.resolve();

     // Всё из UserClient + EngineClient
     Future<List<T>> crossTenantQuery<T>({...});
     Future<void> runMigration(String migrationId);
   }
   ```

2. **Реализовать клиенты в `src/client/`:**
   - `vault_user_client.dart`
   - `vault_engine_client.dart`
   - `vault_worker_client.dart`
   - `vault_admin_client.dart`

3. **Регистрация через `AQPlatform.init()`:**
   ```dart
   // UI приложение
   AQPlatform.init(vault: VaultUserClient(endpoint: url));

   // Воркер
   AQPlatform.init(vault: VaultWorkerClient(endpoint: url));

   // Использование
   final repo = IAQVaultUserClient.instance.versioned<WorkflowGraph>(...);
   ```

**Преимущества:**
- Принцип наименьших привилегий
- Безопасность на уровне типов
- Каждый потребитель видит только свой API

---

## Итоговая оценка

| Критерий | Статус | Оценка |
|----------|--------|--------|
| Структура client/server | ⚠️ | 70% |
| Отдельный server.dart | ✅ | 100% |
| Зависимость от aq_schema | ✅ | 100% |
| Storage только на сервере | ❌ | 0% |
| Типизированные клиенты | ❌ | 0% |
| Handshake протокол | ✅ | 100% |
| Интеграционные тесты | ✅ | 100% |

**Общая оценка:** ⚠️ **70% соответствие**

---

## Заключение

Пакет `dart_vault_package` имеет **хорошую основу** и правильно реализует многие архитектурные принципы (handshake, server.dart, зависимость от aq_schema).

**Критические проблемы:**
1. Смешанный экспорт нарушает принцип "тонкого клиента"
2. Security компоненты доступны клиенту — нарушение безопасности
3. Множественные barrel-файлы создают путаницу

**Рекомендуется:**
1. Реорганизовать barrel-файлы (один клиент, один сервер)
2. Изолировать security на сервере
3. Добавить типизированные клиенты

После исправления этих отклонений пакет будет полностью соответствовать архитектурным принципам AQ Platform.
