# AQ Studio — Migration Plan: SQLite/Drift → Data Service + dart_vault + Supabase

> **Статус:** DRAFT v1.0  
> **Дата:** 2026-03-31  
> **Принцип:** Не просто заменить хранилище — выстроить устойчивую инфраструктуру данных для всей экосистемы.

---

## 1. Контекст и Цель

### Откуда уходим
- SQLite (Drift) — монолитный файл, schema v15, 20+ таблиц
- Dart-приложение имеет прямой доступ к БД (no layer separation)
- Десктоп-only: `dart:io` + `path_provider`

### Куда идём
- **Data Service** — отдельный Dart-сервер, единая точка доступа к данным для всей экосистемы
- **dart_vault v0.2.0** — уровень репозиториев на сервере
- **Supabase (PostgreSQL)** — удалённое хранилище через `SupabaseVaultStorage`
- **aq_mcp_adapter + aq_queue** — очередь для стабильной обработки операций с данными

### Что получаем
- Web-ready: никаких `dart:io` файловых зависимостей на клиенте
- Multi-tenant: каждый проект/пользователь изолирован через `Vault(tenantId: ...)`
- Универсальность: тот же Data Service обслуживает Auth Service, будущие сервисы
- Надёжность: очередь операций через Redis + воркеры
- Публикуемый пакет: `dart_vault` независим от AQ Studio

---

## 2. Целевая Архитектура

```
┌─────────────────────────────────────────────────────────────────┐
│                    AQ Studio Flutter Web                         │
│         (только UI, REST/WebSocket к Data Service)               │
└───────────────────────────┬─────────────────────────────────────┘
                             │ HTTPS
┌────────────────────────────▼─────────────────────────────────────┐
│                  Data Service (Dart / dart_frog)                  │
│                                                                   │
│  GraphService    RunService    KnowledgeService    AuthService    │
│       ↓               ↓              ↓                 ↓         │
│  vault.versioned  vault.logged  vault.direct     vault.direct    │
│       ↓               ↓              ↓                 ↓         │
│            SupabaseVaultStorage (shared backend)                  │
│                                                                   │
│  [aq_mcp_adapter] ← QueueDispatcher ← Redis ← Workers           │
│   workers: PostgresWorker, VectorWorker, NotificationWorker      │
└────────────────────────────┬─────────────────────────────────────┘
                              │ HTTPS (PostgREST)
┌─────────────────────────────▼────────────────────────────────────┐
│                    Supabase (PostgreSQL)                           │
│                                                                   │
│  Projects       Blueprints+nodes    Runs+log    Users/Auth        │
│  Settings       UiBlueprints        VectorChunks  AuditLog        │
└──────────────────────────────────────────────────────────────────┘
```

### Уровни использования dart_vault

| Домен | Тип репозитория | Почему |
|-------|----------------|--------|
| GraphBlueprints | `vault.versioned` | Версии, ветки, lifecycle, access control |
| UiBlueprints | `vault.versioned` | Аналогично |
| WorkflowRuns | `vault.logged` | Audit trail, suspend/resume, rollback |
| SystemLogs | `vault.logged` | История, неизменяемый лог |
| Projects | `vault.direct` | Простой CRUD |
| AppSettings | `vault.direct` | Простой CRUD |
| ApiKeys / LlmProviders | `vault.direct` | Простой CRUD + шифрование отдельно |
| Artifacts | Отдельно (S3/Supabase Storage) | Бинарные данные |
| VectorChunks | Отдельный IVectorStore | ANN-поиск, не key-value |
| ChatMessages | `vault.logged` | Append-only история |
| Companies / Assets | `vault.direct` | CRUD |
| BuilderChatMessages | `vault.logged` | История сообщений |

---

## 3. План Миграции (этапы)

### Этап 0: Фундамент (СЕЙЧАС → 1 неделя)

**Задачи:**
1. Добавить `dart_vault` v0.2.0 в `pkgs/`
2. Создать пакет `pkgs/aq_data_service/` — структура без логики
3. Написать init SQL для Supabase (`doc/supabase_init.sql`) и запустить
4. Создать `SupabaseVaultStorage` (уже в пакете)

**Критерий готовности:**
- `dart_vault` тесты проходят
- Demo app работает с InMemoryStorage
- Supabase проект создан, init SQL выполнен

---

### Этап 1: Data Service — скелет (1-2 недели)

Создать `server_apps/aq_data_service/`:

```
aq_data_service/
  bin/
    main.dart          ← dart_frog / shelf сервер
  lib/
    services/
      graph_service.dart     ← vault.versioned<Blueprint>
      run_service.dart       ← vault.logged<WorkflowRun>
      project_service.dart   ← vault.direct<Project>
      settings_service.dart  ← vault.direct<AppSetting>
    domain/
      models/                ← DTO-классы для каждого домена
    api/
      graph_router.dart      ← HTTP handlers
      run_router.dart
    vault_factory.dart       ← Создаёт Vault(storage: supabase, tenantId: ...)
  pubspec.yaml
```

**Ключевые модели для миграции:**

```dart
// Пример: Blueprint domain model
class Blueprint implements VersionedStorable {
  @override final String id;
  @override final String ownerId;       // = projectId
  @override final List<AccessGrant> accessGrants;
  final String name;
  final String type;                    // workflow | instruction | prompt
  final Map<String, dynamic> graphData; // весь граф как JSON
  // ...
}

// Пример: WorkflowRun domain model
class WorkflowRun implements LoggedStorable {
  @override final String id;
  final String projectId;
  final String blueprintId;
  final String status;
  final Map<String, dynamic>? contextJson;
  final String? suspendedNodeId;
  @override Set<String> get trackedFields =>
      {'status', 'suspendedNodeId', 'contextJson'};
  // ...
}
```

**Критерий готовности:**
- `GraphService.saveBlueprint()` сохраняет в Supabase через SupabaseVaultStorage
- `RunService.createRun()` создаёт run с logged repository
- Postman/curl тесты работают

---

### Этап 2: Очередь операций (aq_mcp_adapter pattern) (1 неделя)

Обернуть Data Service через очередь для надёжности:

```
Redis Queue
  └── Worker: data_worker
        ├── tool: create_run     → RunService.createRun()
        ├── tool: update_run     → RunService.updateStatus()
        ├── tool: save_blueprint → GraphService.saveBlueprint()
        └── tool: query_runs     → RunService.listRuns()
```

**Зачем:**
- Буферизация spike нагрузки (много одновременных ранов)
- Retry при временной недоступности Supabase
- Audit: каждая операция имеет job_id
- Async режим: не блокировать клиента при тяжёлых операциях

**Реализация:**
```dart
// data_worker.dart (WorkerApp) — регистрируется в aq_queue
final queue = RedisJobQueue(connection: redisConn);
queue.registerHandler('save_blueprint', (job) async {
  final service = GraphService(vault: supabaseVault);
  await service.saveBlueprint(Blueprint.fromMap(job.payload));
  return WorkerResult.success({'saved': true});
});
```

**Критерий готовности:**
- Data Service принимает операции через очередь
- Retry работает при временных ошибках

---

### Этап 3: Миграция клиента Flutter (2-3 недели)

Заменить прямые Drift-вызовы на HTTP к Data Service:

**Шаг 3.1: Создать ApiClient**
```dart
// flutter_app/lib/services/data_api_client.dart
class DataApiClient {
  final Dio _dio;
  
  Future<Blueprint?> getBlueprint(String id) async {
    final res = await _dio.get('/graphs/$id');
    return Blueprint.fromMap(res.data);
  }
  
  Future<void> saveBlueprint(Blueprint bp) async {
    await _dio.post('/graphs', data: bp.toMap());
  }
  // ...
}
```

**Шаг 3.2: Заменить репозитории один за одним**

Порядок замены (от простого к сложному):
1. `ProjectRepository` → `DataApiClient.getProjects()`
2. `AppSettings` → `DataApiClient.getSettings()`  
3. `LlmRepository` → `DataApiClient.getLlmProviders()`
4. `GraphRepository` → `DataApiClient.getBlueprint()` (самый важный)
5. `RunRepository` → `DataApiClient.getRun()` + WebSocket для live logs
6. `UiBlueprintRepository` → `DataApiClient.getUiBlueprint()`
7. `ArtifactsRepository` → Supabase Storage (не vault)
8. `VectorSearchHand` → KnowledgeService API

**Шаг 3.3: Удалить Drift**
```yaml
# pubspec.yaml — удалить после всех шагов
# drift: ^2.x  ← УДАЛИТЬ
# drift_dev: ^2.x  ← УДАЛИТЬ
# path_provider: ^2.x  ← УДАЛИТЬ (desktop only)
```

**Критерий готовности:**
- Flutter Web запускается без `dart:io`
- Все CRUD операции идут через Data Service
- Drift полностью удалён

---

### Этап 4: Векторы и Knowledge Base (1-2 недели)

VectorChunks — особый случай: нужен ANN-поиск, не key-value.

```dart
// Интерфейс (уже определён в aq_schema)
abstract class IVectorStore {
  Future<void> upsert(String collection, String id, List<double> vector, Map<String, dynamic> payload);
  Future<List<VectorSearchResult>> search(String collection, List<double> queryVector, {int limit, Map<String, dynamic>? filter});
}

// Реализация через pgvector (Supabase поддерживает из коробки)
class PgVectorStore implements IVectorStore {
  // HTTP к Supabase RPC функции
  Future<List<VectorSearchResult>> search(...) async {
    final res = await _dio.post('/rest/v1/rpc/match_documents', data: {
      'query_embedding': queryVector,
      'match_threshold': 0.8,
      'match_count': limit,
    });
    // ...
  }
}
```

**Критерий готовности:**
- `IndexerHand` использует `PgVectorStore`
- `VectorSearchHand` работает через HTTP к Supabase
- Семантический поиск работает в браузере

---

### Этап 5: Auth Service + Ecosystem данных (2-3 недели)

Вынести авторизацию в отдельный сервис, также на dart_vault:

```
server_apps/aq_auth_service/
  lib/
    services/
      user_service.dart    ← vault.direct<User>
      session_service.dart ← vault.logged<Session> (история входов)
      token_service.dart   ← vault.direct<Token>
```

**Ключевая точка:** тот же `SupabaseVaultStorage` используется Auth Service и Data Service. Tenancy разделяет домены: `auth__users`, `data__blueprints`, и т.д.

**Критерий готовности:**
- Auth Service работает независимо
- Data Service принимает JWT от Auth Service
- AQ Studio аутентифицируется через Auth Service

---

## 4. Решения по Конкретным Проблемам

### Проблема: LlmMetrics (аналитика)

LlmMetrics — write-heavy, нужна аналитика. Не подходит для vault.logged (слишком много записей).

**Решение:** Redis Streams для realtime → батч-запись в отдельную таблицу Supabase каждые N секунд.

```dart
// RunService.appendMetric() → Redis Stream
// MetricsWorker → Supabase INSERT BATCH каждые 5 секунд
```

### Проблема: Артефакты (бинарные файлы)

Drift хранил их как BLOB. vault работает с JSON, не с бинарными данными.

**Решение:** Supabase Storage (S3-совместимый) для файлов + `vault.direct<ArtifactMeta>` для метаданных.

```dart
class ArtifactMeta implements DirectStorable {
  final String id;
  final String storagePath; // ← путь в Supabase Storage
  final String contentType;
  final int sizeBytes;
  // ...
}
```

### Проблема: Миграция данных из SQLite

Текущие данные из SQLite нужно перенести в Supabase.

**Решение:** Одноразовый скрипт миграции:
```dart
// scripts/migrate_sqlite_to_supabase.dart
final db = AppDatabase();
final vault = Vault(storage: supabaseStorage, tenantId: projectId);

// Мигрировать проекты
final projects = await db.getAllProjects();
final projRepo = vault.direct<Project>(...);
for (final p in projects) {
  await projRepo.save(Project.fromDrift(p));
}

// Мигрировать графы с их версиями
// ...
```

### Проблема: Offline режим (если нужен)

Для десктоп-версии может понадобиться offline.

**Решение:** `Vault` с `InMemoryVaultStorage` как кэш + sync worker к Supabase. dart_vault абстракция делает это тривиальным — меняем только storage.

---

## 5. Когда и как использовать dart_vault

### На уровне клиента (Flutter Web)
**НЕ использовать** — клиент не должен знать о хранилище.

### На уровне Data Service (сервер)
**ДА** — это основное место. vault работает через `SupabaseVaultStorage`.

```
Data Service
  └── vault.versioned<Blueprint>(storage: supabaseStorage, tenantId: projectId)
  └── vault.logged<WorkflowRun>(storage: supabaseStorage, tenantId: projectId)
```

### На уровне Auth Service
**ДА** — тот же паттерн, другой tenantId namespace.

### На уровне тестов
**ДА** — `InMemoryVaultStorage` делает тесты мгновенными без БД.

---

## 6. Чеклист Готовности к Production

- [ ] `dart_vault` unit-тесты: DirectRepository, VersionedRepository, LoggedRepository
- [ ] `SupabaseVaultStorage` integration-тест (с реальным Supabase)
- [ ] init SQL выполнен, RLS настроен на всех таблицах
- [ ] Data Service: все эндпоинты покрыты тестами
- [ ] Очередь: retry-логика проверена при падении воркера
- [ ] Миграция данных: dry-run на копии базы
- [ ] Миграция данных: production run + верификация count(*)
- [ ] Flutter Web: нет зависимостей от `dart:io`
- [ ] Мониторинг: логирование каждой операции vault
- [ ] Rollback-план: готов сценарий отката на Drift если что-то пошло не так

---

## 7. Сроки (ориентировочно)

| Этап | Длительность | Риски |
|------|-------------|-------|
| 0 — Фундамент | 1 неделя | Низкий |
| 1 — Data Service скелет | 1-2 недели | Средний |
| 2 — Очередь операций | 1 неделя | Низкий |
| 3 — Миграция Flutter клиента | 2-3 недели | **Высокий** — много файлов |
| 4 — Векторы и KnowledgeBase | 1-2 недели | Средний |
| 5 — Auth + Ecosystem | 2-3 недели | Средний |
| **Итого** | **8-12 недель** | |

Самый рискованный шаг — Этап 3 (замена Drift во Flutter). Рекомендуется делать по одному репозиторию за раз, с параллельной работой обеих версий через feature flag.

---

## 8. Ключевые Решения

1. **dart_vault на сервере, не на клиенте.** Клиент видит только HTTP API.

2. **Один Supabase проект — несколько сервисов.** Tenancy через префиксы коллекций (`auth__`, `data__`, `analytics__`). RLS обеспечивает безопасность на уровне БД.

3. **aq_mcp_adapter как шина операций.** Все тяжёлые записи идут через очередь. Лёгкие чтения — напрямую через HTTP.

4. **dart_vault публикуется отдельно.** Пакет ничего не знает об AQ Studio. Это универсальный storage engine для любого Dart-проекта в экосистеме.

5. **InMemoryVaultStorage в тестах.** Тесты Data Service работают без Supabase — просто `Vault()`.

---

*Документ составлен на основе анализа кодовой базы AQ Studio, архитектурных принципов из data_layer_arch.md и MCP_protocol_rules.md.*
