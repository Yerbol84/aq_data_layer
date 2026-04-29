# dart_vault Architecture

**Версия:** 0.3.0
**Дата:** 2026-04-07
**Статус:** Production Ready

---

## Оглавление

1. [Обзор архитектуры](#обзор-архитектуры)
2. [Принципы проектирования](#принципы-проектирования)
3. [Унифицированная архитектура](#унифицированная-архитектура)
4. [Компоненты системы](#компоненты-системы)
5. [Storage Types](#storage-types)
6. [Multi-tenancy](#multi-tenancy)
7. [PostgreSQL Implementation](#postgresql-implementation)
8. [RPC Protocol](#rpc-protocol)
9. [Диаграммы](#диаграммы)

---

## Обзор архитектуры

dart_vault — это универсальный data layer построенный по принципу **"тонкий клиент + чистая архитектура"**.

### Ключевые характеристики

- **Тонкий клиент** — клиент не знает о базе данных, только о репозиториях
- **Единая схема** — все домены определены в `aq_schema`
- **Унифицированные константы** — все компоненты используют `VersionedStorageContract`
- **Multi-tenancy** — изоляция данных на уровне `tenant_id`
- **PostgreSQL-оптимизация** — специализированные реализации для максимальной производительности

### Архитектурная диаграмма

```
┌─────────────────────────────────────────────────────────────────┐
│                     Flutter/Dart Client                         │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │   Vault      │  │ Repository   │  │    Buffer    │         │
│  │  (Singleton) │──│  (Direct/    │──│   (Local)    │         │
│  │              │  │   Versioned/ │  │              │         │
│  │              │  │   Logged)    │  │              │         │
│  └──────┬───────┘  └──────────────┘  └──────────────┘         │
│         │                                                       │
│         │ HTTP RPC                                             │
└─────────┼───────────────────────────────────────────────────────┘
          │
          │ POST /vault/rpc
          │ POST /vault/handshake
          │
┌─────────▼───────────────────────────────────────────────────────┐
│                      Data Service (Dart)                        │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    VaultRegistry                         │  │
│  │  • Регистрация доменов из aq_schema                     │  │
│  │  • RPC dispatch                                          │  │
│  │  • Handshake protocol                                    │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                         │
│  ┌────────────────────▼─────────────────────────────────────┐  │
│  │              PostgresVaultStorage                        │  │
│  │  • CRUD операции с JSONB                                │  │
│  │  • Фильтрация по tenant_id                              │  │
│  │  • Запросы с пагинацией                                 │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                         │
│  ┌────────────────────▼─────────────────────────────────────┐  │
│  │         PostgresVersionedRepository                      │  │
│  │  • Оптимизированная реализация для PostgreSQL           │  │
│  │  • Работа с _versions и _current таблицами              │  │
│  │  • Использует VersionedStorageContract                  │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                         │
└───────────────────────┼─────────────────────────────────────────┘
                        │
                        │ SQL
                        │
┌───────────────────────▼─────────────────────────────────────────┐
│                    PostgreSQL Database                          │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │   projects   │  │ workflows_   │  │ workflows_   │         │
│  │              │  │  versions    │  │  current     │         │
│  │ (Direct)     │  │ (Versioned)  │  │ (Pointer)    │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
│                                                                 │
│  Все таблицы имеют tenant_id для изоляции данных               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Принципы проектирования

### 1. Единая схема (Single Source of Truth)

Все домены определены в пакете `aq_schema`:

```dart
// aq_schema/lib/data_layer/storable/
class WorkflowGraph implements VersionedStorable {
  final String id;
  final String name;
  final List<Node> nodes;
  final List<Edge> edges;
  // ...
}
```

Эта же модель используется:
- На клиенте (Flutter)
- На сервере (Data Service)
- В тестах

### 2. Тонкий клиент

Клиент **не знает** о:
- PostgreSQL
- Схемах таблиц
- SQL запросах
- Миграциях

Клиент **знает** только о:
- Репозиториях (Direct, Versioned, Logged)
- Моделях из `aq_schema`
- HTTP RPC протоколе

### 3. Унифицированные константы

Все компоненты используют **одни и те же константы** из `VersionedStorageContract`:

```dart
abstract final class VersionedStorageContract {
  // Имена полей
  static const String kNodeId = 'node_id';
  static const String kEntityId = 'entity_id';
  static const String kTenantId = 'tenant_id';
  static const String kVersion = 'version';
  static const String kStatus = 'status';
  static const String kBranch = 'branch';
  static const String kData = 'data';
  static const String kCreatedAt = 'created_at';
  static const String kCreatedBy = 'created_by';
  static const String kSequenceNumber = 'sequence_number';

  // Имена таблиц
  static String versionsTable(String collection) => '${collection}_versions';
  static String currentTable(String collection) => '${collection}_current';

  // Конвертеры
  static Map<String, dynamic> toPostgresVersionsRow(Map<String, dynamic> node);
  static Map<String, dynamic> fromPostgresVersionsRow(Map<String, dynamic> row);
}
```

Это гарантирует:
- ✅ PostgresSchemaDeployer создает таблицы с правильными полями
- ✅ PostgresVersionedRepository использует те же имена
- ✅ VersionedRepositoryImpl (InMemory) использует те же структуры
- ✅ Нет рассогласования между компонентами

### 4. PostgreSQL-оптимизация

Для максимальной производительности созданы специализированные реализации:

- **PostgresVersionedRepository** — работает напрямую с SQL, без промежуточных слоев
- **PostgresVaultStorage** — использует JSONB для эффективного хранения
- **PostgresSchemaDeployer** — создает оптимальные индексы

---

## Унифицированная архитектура

### Проблема (до унификации)

Раньше разные компоненты использовали разные имена полей:

```dart
// PostgresSchemaDeployer создавал:
CREATE TABLE workflows_versions (
  node_id TEXT,
  entity_id TEXT,
  ...
);

// Но VersionedRepositoryImpl использовал:
final nodeId = data['nodeId'];  // ❌ Несоответствие!
```

### Решение (после унификации)

Все компоненты используют `VersionedStorageContract`:

```dart
// PostgresSchemaDeployer:
CREATE TABLE workflows_versions (
  ${VersionedStorageContract.kNodeId} TEXT,      // 'node_id'
  ${VersionedStorageContract.kEntityId} TEXT,    // 'entity_id'
  ...
);

// PostgresVersionedRepository:
final nodeId = row[VersionedStorageContract.kNodeId];  // ✅ Согласовано!

// VersionedRepositoryImpl:
final nodeId = data[VersionedStorageContract.kNodeId]; // ✅ Согласовано!
```

### Преимущества

1. **Нет рассогласования** — все компоненты используют одни константы
2. **Легко рефакторить** — изменение в одном месте
3. **Типобезопасность** — константы проверяются на этапе компиляции
4. **Документация** — константы служат документацией структуры данных

---

## Компоненты системы

### 1. Vault (Клиент)

Singleton, предоставляющий доступ к репозиториям:

```dart
class Vault {
  static Vault? _instance;

  static Future<void> connect(String endpoint, {String? tenantId}) async {
    _instance = Vault(
      storage: RemoteVaultStorage(endpoint: endpoint, tenantId: tenantId),
      tenantId: tenantId ?? 'system',
    );
  }

  static Vault get instance => _instance!;

  DirectRepository<T> direct<T extends DirectStorable>({...});
  VersionedRepository<T> versioned<T extends VersionedStorable>({...});
  LoggedRepository<T> logged<T extends LoggedStorable>({...});
}
```

### 2. VaultRegistry (Сервер)

Центральный реестр доменов на сервере:

```dart
class VaultRegistry {
  final VaultStorage Function(String tenantId) _storageFactory;
  final SchemaDeployer _deployer;
  final Map<String, DomainRegistration> _domains = {};

  // Регистрация домена
  VaultRegistry register(DomainRegistration domain) {
    _domains[domain.collection] = domain;
    return this;
  }

  // Deploy схемы
  Future<void> deploy() => _deployer.ensureSchema(_domains.values.toList());

  // RPC dispatch
  Future<dynamic> dispatch({
    required String collection,
    required String operation,
    required Map<String, dynamic> args,
    required String tenantId,
  }) async {
    final reg = _domains[collection];
    final storage = _storageFactory(tenantId);
    final vault = Vault(storage: storage, tenantId: 'system');

    // Выбор правильной реализации
    if (storage is PostgresVaultStorage && reg.mode == StorageMode.versioned) {
      final repo = PostgresVersionedRepository(
        connection: storage.connection,
        collection: reg.collection,
        tenantId: tenantId,
        fromMap: reg.fromMap,
      );
      return await _dispatchVersioned(repo, operation, args);
    }
    // ...
  }
}
```

### 3. PostgresVaultStorage

Базовое хранилище для PostgreSQL:

```dart
class PostgresVaultStorage implements VaultStorage {
  final Connection connection;
  final String tenantId;

  @override
  Future<void> put(String collection, String id, Map<String, dynamic> data) async {
    await connection.execute('''
      INSERT INTO $collection (id, tenant_id, data, created_at, updated_at)
      VALUES (\$1, \$2, \$3, NOW(), NOW())
      ON CONFLICT (id, tenant_id)
      DO UPDATE SET data = EXCLUDED.data, updated_at = NOW()
    ''', parameters: [id, tenantId, data]);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final result = await connection.execute('''
      SELECT data FROM $collection
      WHERE id = \$1 AND tenant_id = \$2
    ''', parameters: [id, tenantId]);

    return result.isEmpty ? null : result.first[0] as Map<String, dynamic>;
  }

  // ... другие методы
}
```

### 4. PostgresVersionedRepository

Оптимизированная реализация для версионированных сущностей:

```dart
class PostgresVersionedRepository<T extends VersionedStorable>
    implements VersionedRepository<T> {
  final Connection _connection;
  final String _collection;
  final String _tenantId;
  final T Function(Map<String, dynamic>) _fromMap;

  late final String _versionsTable;
  late final String _currentTable;

  PostgresVersionedRepository({...}) {
    _versionsTable = VersionedStorageContract.versionsTable(_collection);
    _currentTable = VersionedStorageContract.currentTable(_collection);
  }

  @override
  Future<VersionNode> createEntity(T model) async {
    final nodeId = _uuid();
    await _connection.execute('''
      INSERT INTO $_versionsTable (
        ${VersionedStorageContract.kNodeId},
        ${VersionedStorageContract.kEntityId},
        ${VersionedStorageContract.kTenantId},
        ${VersionedStorageContract.kStatus},
        ${VersionedStorageContract.kBranch},
        ${VersionedStorageContract.kData},
        ${VersionedStorageContract.kCreatedAt}
      ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, NOW())
    ''', parameters: [
      nodeId,
      model.id,
      _tenantId,
      VersionStatus.draft.name,
      'main',
      model.toMap(),
    ]);

    return VersionNode(
      nodeId: nodeId,
      entityId: model.id,
      status: VersionStatus.draft,
      branch: 'main',
      data: model,
      createdAt: DateTime.now(),
    );
  }

  // ... другие методы
}
```

### 5. PostgresSchemaDeployer

Автоматическое создание таблиц:

```dart
class PostgresSchemaDeployer implements SchemaDeployer {
  final Connection pool;

  @override
  Future<void> ensureSchema(List<DomainRegistration> domains) async {
    await _ensureMigrationsTable();

    for (final domain in domains) {
      final exists = await _tableExists(domain.collection);

      if (exists) {
        await _validateTableStructure(domain);
      } else {
        await _createTablesForDomain(domain);
      }
    }
  }

  Future<void> _createVersionedTables(DomainRegistration domain) async {
    final versionsTable = VersionedStorageContract.versionsTable(domain.collection);
    final currentTable = VersionedStorageContract.currentTable(domain.collection);

    await pool.execute('''
      CREATE TABLE IF NOT EXISTS $versionsTable (
        ${VersionedStorageContract.kNodeId} TEXT PRIMARY KEY,
        ${VersionedStorageContract.kEntityId} TEXT NOT NULL,
        ${VersionedStorageContract.kParentNodeId} TEXT,
        ${VersionedStorageContract.kTenantId} TEXT NOT NULL,
        ${VersionedStorageContract.kVersion} TEXT,
        ${VersionedStorageContract.kStatus} TEXT NOT NULL,
        ${VersionedStorageContract.kBranch} TEXT NOT NULL DEFAULT 'main',
        ${VersionedStorageContract.kSequenceNumber} INTEGER NOT NULL DEFAULT 1,
        ${VersionedStorageContract.kCreatedBy} TEXT NOT NULL DEFAULT '',
        ${VersionedStorageContract.kCreatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ${VersionedStorageContract.kData} JSONB NOT NULL
      )
    ''');

    await pool.execute('''
      CREATE TABLE IF NOT EXISTS $currentTable (
        ${VersionedStorageContract.kEntityId} TEXT NOT NULL,
        ${VersionedStorageContract.kTenantId} TEXT NOT NULL,
        ${VersionedStorageContract.kNodeId} TEXT NOT NULL,
        ${VersionedStorageContract.kUpdatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (${VersionedStorageContract.kEntityId}, ${VersionedStorageContract.kTenantId})
      )
    ''');
  }
}
```

---

## Storage Types

### Direct Storage

Простые CRUD операции без версионирования:

**Структура таблицы:**
```sql
CREATE TABLE projects (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)
);
```

**Use cases:**
- Проекты
- Настройки
- Справочники
- Простые сущности без истории

### Versioned Storage

Версионирование с ветками и semver:

**Структура таблиц:**
```sql
-- Все версии
CREATE TABLE workflows_versions (
  node_id TEXT PRIMARY KEY,
  entity_id TEXT NOT NULL,
  parent_node_id TEXT,
  tenant_id TEXT NOT NULL,
  version TEXT,
  status TEXT NOT NULL,  -- draft | published | snapshot
  branch TEXT NOT NULL DEFAULT 'main',
  sequence_number INTEGER NOT NULL DEFAULT 1,
  created_by TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  data JSONB NOT NULL
);

-- Указатель на текущую версию
CREATE TABLE workflows_current (
  entity_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  node_id TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (entity_id, tenant_id)
);
```

**Lifecycle:**
```
createEntity() → DRAFT
    ↓
updateDraft() → DRAFT (modified)
    ↓
publishDraft() → PUBLISHED (v1.0.0)
    ↓
snapshotVersion() → SNAPSHOT (immutable)
```

**Use cases:**
- Workflow graphs
- Instruction graphs
- Prompt graphs
- Документы с историей изменений

### Logged Storage

Audit trail с полной историей:

**Структура таблиц:**
```sql
-- Основная таблица
CREATE TABLE runs (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)
);

-- Лог изменений
CREATE TABLE runs_log (
  entry_id SERIAL PRIMARY KEY,
  entity_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  operation TEXT NOT NULL,  -- create | update | delete
  actor_id TEXT,
  changes JSONB,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Use cases:**
- Workflow runs
- User sessions
- Audit logs
- Любые сущности требующие полной истории изменений

---

## Multi-tenancy

### Принцип

Изоляция данных на уровне `tenant_id` колонки:

```sql
-- Все таблицы имеют tenant_id
CREATE TABLE projects (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,
  PRIMARY KEY (id, tenant_id)
);

-- Все запросы автоматически фильтруются
SELECT * FROM projects WHERE tenant_id = 'user-123';
```

### Преимущества

1. **Простота** — не нужно создавать отдельные схемы/базы для каждого tenant
2. **Производительность** — один connection pool для всех tenant
3. **Backup** — один backup для всех данных
4. **Миграции** — одна миграция применяется ко всем tenant

### Безопасность

- `tenant_id` извлекается из JWT токена на уровне HTTP handler
- Все запросы автоматически фильтруются по `tenant_id`
- Невозможно получить данные другого tenant

---

## PostgreSQL Implementation

### Оптимизации

1. **JSONB для data** — эффективное хранение и индексирование
2. **Composite Primary Key** — (id, tenant_id) для быстрого поиска
3. **Индексы на JSONB полях** — для быстрой фильтрации
4. **Prepared statements** — защита от SQL injection

### Транзакции

```dart
await storage.transaction((tx) async {
  await tx.put('projects', 'p1', project1.toMap());
  await tx.put('projects', 'p2', project2.toMap());
  // Если ошибка — откат всех изменений
});
```

### Валидация схемы

При старте сервера автоматически проверяется:
- Существование таблиц
- Наличие всех обязательных колонок
- Правильность типов колонок

Если структура не совпадает — выбрасывается исключение с подробным описанием.

---

## RPC Protocol

### Handshake

```http
POST /vault/handshake
Content-Type: application/json

{
  "tenantId": "user-123"
}
```

**Response:**
```json
{
  "serverVersion": "0.3.0",
  "tenantId": "user-123",
  "collections": [
    {
      "name": "projects",
      "mode": "direct"
    },
    {
      "name": "workflow_graphs",
      "mode": "versioned"
    }
  ],
  "capabilities": ["direct", "versioned", "logged"],
  "compatible": true
}
```

### RPC Call

```http
POST /vault/rpc
Content-Type: application/json

{
  "collection": "workflow_graphs",
  "operation": "put",
  "tenantId": "user-123",
  "args": {
    "data": {
      "id": "wf-1",
      "name": "My Workflow",
      "nodes": [],
      "edges": []
    }
  }
}
```

**Response:**
```json
{
  "result": {
    "nodeId": "node_123",
    "entityId": "wf-1",
    "status": "draft",
    "version": null,
    "createdAt": "2026-04-07T10:00:00Z"
  }
}
```

### Операции

**Direct:**
- `put` — создать/обновить
- `get` — получить по ID
- `delete` — удалить
- `query` — поиск с фильтрацией
- `queryPage` — поиск с пагинацией
- `count` — подсчет

**Versioned:**
- `put` — создать entity (draft)
- `updateDraft` — обновить draft
- `publishDraft` — опубликовать draft
- `snapshotVersion` — создать snapshot
- `deleteVersion` — удалить версию
- `delete` — удалить всю сущность
- `getCurrent` — получить текущую версию
- `getVersion` — получить конкретную версию
- `listVersions` — список всех версий
- `createBranch` — создать ветку
- `mergeToMain` — слить ветку
- `listBranches` — список веток

**Logged:**
- `put` — создать/обновить с актором
- `get` — получить текущее состояние
- `delete` — удалить с актором
- `query` — поиск
- `getHistory` — получить историю
- `rollbackTo` — откатить к версии

---

## Диаграммы

### Lifecycle: Versioned Storage

```
┌─────────────┐
│ createEntity│
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   DRAFT     │◄──────┐
│  (editable) │       │
└──────┬──────┘       │
       │              │
       │ updateDraft  │
       └──────────────┘
       │
       │ publishDraft
       ▼
┌─────────────┐
│  PUBLISHED  │
│  (v1.0.0)   │
└──────┬──────┘
       │
       │ snapshotVersion
       ▼
┌─────────────┐
│  SNAPSHOT   │
│ (immutable) │
└─────────────┘
```

### Data Flow: Client → Server

```
┌──────────┐
│  Client  │
└────┬─────┘
     │
     │ 1. workflows.createEntity(workflow)
     ▼
┌────────────────┐
│ RemoteVault    │
│ Storage        │
└────┬───────────┘
     │
     │ 2. POST /vault/rpc
     │    { collection: "workflow_graphs",
     │      operation: "put",
     │      args: { data: {...} } }
     ▼
┌────────────────┐
│ VaultRegistry  │
└────┬───────────┘
     │
     │ 3. dispatch()
     │    → PostgresVersionedRepository
     ▼
┌────────────────┐
│ PostgresVersioned│
│ Repository     │
└────┬───────────┘
     │
     │ 4. INSERT INTO workflows_versions
     ▼
┌────────────────┐
│  PostgreSQL    │
└────────────────┘
```

---

## Заключение

Архитектура dart_vault обеспечивает:

✅ **Чистоту** — разделение клиента и сервера
✅ **Унификацию** — единые константы и контракты
✅ **Производительность** — PostgreSQL-оптимизированные реализации
✅ **Безопасность** — multi-tenancy и изоляция данных
✅ **Надежность** — ACID транзакции и валидация схемы
✅ **Гибкость** — три типа хранилищ для разных use cases

Система готова к production использованию.
