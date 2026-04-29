# AQ Studio — Migration Plan v2
## SQLite/Drift → Data Service + dart_vault v0.3.0 + Supabase

> **Status:** APPROVED FOR EXECUTION  
> **Version:** 2.0  
> **Date:** 2026-03-31  
> **Принцип:** Надёжность → Корректность → Скорость. Не ломать прод, пока новое не готово.

---

## Архитектурное решение

```
┌──────────────────────┐     HTTPS      ┌─────────────────────────────────┐
│   Flutter Web        │◄──────────────►│   Data Service  (dart/frog)     │
│   (only UI + HTTP)   │                │                                 │
└──────────────────────┘                │  GraphService  ← vault.versioned│
                                        │  RunService    ← vault.logged   │
┌──────────────────────┐     HTTPS      │  ProjectService← vault.direct   │
│  Other Ecosystem     │◄──────────────►│  FileService   ← ArtifactVault  │
│  Services (Auth etc) │                │  KBService     ← KnowledgeVault │
└──────────────────────┘                └────────────┬────────────────────┘
                                                     │ HTTP (PostgREST)
                                        ┌────────────▼────────────────────┐
                                        │   Supabase (PostgreSQL)          │
                                        │   + Storage (артефакты/файлы)    │
                                        │   + pgvector (эмбеддинги)        │
                                        └─────────────────────────────────┘
```

### Ключевые решения

| Вопрос | Решение |
|--------|---------|
| Где использовать dart_vault? | На **сервере** (Data Service). Клиент — только HTTP. |
| Один сервис или несколько? | Один Data Service на старте. Разбить на домены позже. |
| Шифрование — чья задача? | **Пользователя пакета**. dart_vault хранит байты как есть. |
| Как синхронизировать схемы? | Через shared пакет (aq_schema). Версионирование контракта. |
| Клиентский SDK? | `RemoteVaultStorage` в том же пакете — 2 режима: local / remote. |
| Векторы | pgvector через Supabase RPC — имплементировать PgVectorStorage. |
| Файлы | Supabase Storage — имплементировать SupabaseArtifactStorage. |
| Реалтайм потоки | Server-Sent Events (TODO в RemoteVaultStorage). Сейчас — polling. |

---

## Текущее состояние (ОТКУДА)

| Компонент | Технология | Проблема |
|-----------|-----------|---------|
| БД | SQLite/Drift, schema v15 | Нет на web, нет concurrent writes |
| Векторы | SQLite + in-memory | Нет ANN-индексов, медленно |
| Файлы | BLOB в SQLite | Очень медленно для больших файлов |
| Клиент | Прямой доступ к Drift | Нет разделения клиент/сервер |

---

## Этапы миграции

---

### Этап 0 — Фундамент (3–5 дней)

**Цель:** подготовить инфраструктуру, не трогать прод.

#### 0.1. Supabase setup

```bash
# 1. Создать проект на supabase.com
# 2. Получить URL и anon key
# 3. Запустить init SQL:
psql $DATABASE_URL < pkgs/dart_vault/doc/supabase_init.sql
```

Добавить pgvector:
```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

#### 0.2. Добавить dart_vault в workspace

```yaml
# pubspec.yaml (корневой)
workspace:
  - pkgs/dart_vault
  - server_apps/aq_data_service   # создать ниже
  - ...
```

#### 0.3. Создать структуру Data Service

```
server_apps/aq_data_service/
  bin/
    main.dart                    ← HTTP сервер (dart_frog)
  lib/
    services/
      graph_service.dart
      run_service.dart
      project_service.dart
      file_service.dart
      knowledge_service.dart
    domain/
      models/
        blueprint.dart           ← implements VersionedStorable
        workflow_run.dart        ← implements LoggedStorable
        project.dart             ← implements DirectStorable
        artifact_meta.dart       ← implements ArtifactEntry
        kb_document.dart         ← implements KnowledgeDocument
    api/
      vault_rpc_handler.dart     ← обрабатывает POST /vault/rpc
      vault_handshake.dart       ← обрабатывает POST /vault/handshake
      vault_watch.dart           ← SSE GET /vault/watch (TODO)
    vault_factory.dart           ← создаёт Vault/ArtifactVault/KnowledgeVault
  pubspec.yaml
  Dockerfile
```

#### 0.4. Написать VaultFactory

```dart
// lib/vault_factory.dart
class VaultFactory {
  static Vault forTenant(String tenantId) => Vault(
    storage: SupabaseVaultStorage(
      url: Platform.environment['SUPABASE_URL']!,
      anonKey: Platform.environment['SUPABASE_SERVICE_KEY']!,
    ),
    tenantId: tenantId,
  );

  static ArtifactVault artifactsForTenant(String tenantId) => ArtifactVault(
    metaStorage: SupabaseVaultStorage(...),
    // binaryStore: SupabaseArtifactStorage(...),  // TODO Этап 3
    binaryStore: LocalArtifactStorage(basePath: Platform.environment['ARTIFACTS_PATH']!),
    tenantId: tenantId,
  );
}
```

**Критерий:** Data Service стартует, `/vault/handshake` возвращает `compatible: true`.

---

### Этап 1 — Domain Models (3–5 дней)

**Цель:** реализовать domain-модели в Data Service, покрыть тестами.

#### 1.1. Blueprint (VersionedStorable)

```dart
class Blueprint implements VersionedStorable {
  @override final String id;
  @override final String ownerId;       // = projectId
  @override final List<AccessGrant> accessGrants;
  final String name;
  final String blueprintType;           // workflow | instruction | prompt
  final Map<String, dynamic> graphData;

  @override Set<String> get trackedFields => {};
  // ...
}
```

Маппинг из Drift:
- `GraphBlueprints.id` → `Blueprint.id`
- `GraphBlueprints.projectId` → `Blueprint.ownerId`
- `GraphVersions.dataJson` → `Blueprint.graphData`

#### 1.2. WorkflowRun (LoggedStorable)

```dart
class WorkflowRun implements LoggedStorable {
  @override final String id;
  final String projectId;
  final String blueprintId;
  final String status;           // pending|running|suspended|completed|failed
  final Map<String, dynamic>? contextJson;
  final String? suspendedNodeId;
  @override Set<String> get trackedFields => {'status', 'suspendedNodeId', 'contextJson'};
}
```

Маппинг:
- `WorkflowRuns` → `WorkflowRun` (1:1)
- Логи рана → `LoggedRepository.getHistory()` (заменяет `SystemLogs`)

#### 1.3. Остальные модели

| Drift таблица | dart_vault модель | Тип репозитория |
|--------------|------------------|----------------|
| `Projects` | `Project` | `DirectStorable` |
| `UiBlueprints` + `UiBlueprintVersions` | `UiBlueprint` | `VersionedStorable` |
| `AiProviders` + `ApiKeys` | `LlmProvider` | `DirectStorable` |
| `Companies` | `Company` | `DirectStorable` |
| `CompanyAssets` | `Asset` | `DirectStorable` |
| `AppSettings` | `Setting` | `DirectStorable` |
| `ChatMessages` | `ChatMessage` | `LoggedStorable` |
| `BuilderChatMessages` | `BuilderMessage` | `LoggedStorable` |
| `Artifacts` | `ArtifactMeta` | `ArtifactEntry` |
| `VectorChunks` | `VectorChunk` | `VectorEntry` |
| `KnowledgeBases` | `KnowledgeBase` | `DirectStorable` |

**Критерий:** все модели написаны, unit-тесты с InMemoryVaultStorage проходят.

---

### Этап 2 — Data Service API (5–7 дней)

**Цель:** реализовать HTTP API Data Service, покрыть integration-тестами.

#### 2.1. RPC Handler

```dart
// POST /vault/rpc
Future<Response> vaultRpcHandler(Request request) async {
  final body   = await request.body();
  final rpcReq = VaultRpcRequest.fromJson(body);
  final jwt    = request.headers['Authorization'];
  final tenantId = extractTenantFromJwt(jwt);

  final vault = VaultFactory.forTenant(tenantId);
  final result = await _dispatch(vault, rpcReq);
  return Response.ok(VaultRpcResponse.ok(result).toJson(),
      headers: {'Content-Type': 'application/json'});
}
```

#### 2.2. Endpoints

```
POST /vault/handshake   → HandshakeResponse
POST /vault/rpc         → VaultRpcResponse
GET  /vault/watch       → SSE stream (TODO — пока пустой)
GET  /health            → { ok: true }
```

#### 2.3. Специальные endpoints для файлов

```
POST /files/upload      → multipart, возвращает artifactId
GET  /files/{id}        → стримит байты
DELETE /files/{id}      → удаляет файл + metadata
```

**Критерий:** curl тест — сохранить Blueprint, прочитать обратно.

---

### Этап 3 — Миграция данных (3–5 дней)

**Цель:** перенести существующие данные из SQLite в Supabase.

#### 3.1. Скрипт миграции

```bash
# scripts/migrate_sqlite_to_supabase.dart
```

```dart
final db       = AppDatabase();
final tenantId = args.first; // projectId или 'system'
final vault    = VaultFactory.forTenant(tenantId);

// ── Проекты ─────────────────────────────────────────────────────────────────
final projRepo = vault.direct<Project>(collection: 'projects', fromMap: Project.fromMap);
for (final p in await db.getAllProjects()) {
  await projRepo.save(Project.fromDrift(p));
  print('Migrated project ${p.id}');
}

// ── Графы (важно: сохранить историю версий) ──────────────────────────────────
final bpRepo = vault.versioned<Blueprint>(collection: 'blueprints', fromMap: Blueprint.fromMap);
final blueprints = await db.getAllBlueprints();
for (final bp in blueprints) {
  final versions = await db.getVersionsForBlueprint(bp.id);
  // Создать первую версию как DRAFT, затем опубликовать последнюю
  final initial = Blueprint.fromDrift(bp, versions.first);
  final node0 = await bpRepo.createEntity(initial);
  // Публиковать промежуточные версии для сохранения истории
  for (var i = 1; i < versions.length; i++) {
    final draft = await bpRepo.createDraftFrom(node0.nodeId,
        Blueprint.fromDrift(bp, versions[i]));
    await bpRepo.publishDraft(draft.nodeId, increment: IncrementType.patch);
  }
}

// ── Раны (логи сохраняются как LoggedRepository history) ─────────────────────
// ...
```

#### 3.2. Dry-run + verification

```bash
# 1. Dry-run на staging
dart scripts/migrate_sqlite_to_supabase.dart --dry-run --project-id=$ID

# 2. Сверить count(*)
SELECT 'blueprints' as tbl, COUNT(*) FROM blueprints__meta
UNION ALL
SELECT 'runs', COUNT(*) FROM runs;

# 3. Реальный прогон на prod
dart scripts/migrate_sqlite_to_supabase.dart --project-id=$ID
```

**Критерий:** все count совпадают, данные читаются через Data Service API.

---

### Этап 4 — Клиент Flutter (7–10 дней)

**Цель:** заменить прямые Drift-вызовы на HTTP к Data Service.

#### 4.1. Создать DataApiClient

```dart
// lib/services/data_api_client.dart
class DataApiClient {
  final Vault _vault; // RemoteVaultStorage

  DataApiClient({required String dataServiceUrl, required String accessToken})
      : _vault = Vault(
          storage: RemoteVaultStorage(
            endpoint: dataServiceUrl,
            tenantId: currentProjectId,
            authToken: accessToken,
          ),
          tenantId: currentProjectId,
        );

  late final blueprints = _vault.versioned<Blueprint>(
    collection: 'blueprints', fromMap: Blueprint.fromMap,
  );
  late final runs = _vault.logged<WorkflowRun>(
    collection: 'runs', fromMap: WorkflowRun.fromMap,
  );
  late final projects = _vault.direct<Project>(
    collection: 'projects', fromMap: Project.fromMap,
  );
  // ...
}
```

#### 4.2. Порядок замены репозиториев (от простого к сложному)

| # | Репозиторий | Сложность | Feature Flag |
|---|------------|-----------|-------------|
| 1 | `ProjectRepository` | ⭐ | `use_remote_projects` |
| 2 | `AppSettings` | ⭐ | `use_remote_settings` |
| 3 | `LlmRepository` | ⭐⭐ | `use_remote_llm` |
| 4 | `UiBlueprintRepository` | ⭐⭐ | `use_remote_ui_blueprints` |
| 5 | `GraphRepository` | ⭐⭐⭐ | `use_remote_graphs` |
| 6 | `RunRepository` | ⭐⭐⭐ | `use_remote_runs` |
| 7 | `ArtifactsRepository` | ⭐⭐ | `use_remote_artifacts` |
| 8 | `VectorSearchHand` | ⭐⭐⭐ | `use_remote_vectors` |

#### 4.3. Feature flag pattern

```dart
// Dual mode — работают оба пути одновременно
Future<Blueprint?> getBlueprint(String id) async {
  if (FeatureFlags.useRemoteGraphs) {
    return await _apiClient.blueprints.getCurrent(id);
  }
  return _oldDriftRepo.getBlueprint(id);
}
```

#### 4.4. Удаление Drift (финал)

```yaml
# pubspec.yaml — удалить после всех шагов
# drift: ...          ← УДАЛИТЬ
# drift_dev: ...      ← УДАЛИТЬ
# path_provider: ...  ← УДАЛИТЬ
```

**Критерий:** Flutter Web запускается без `dart:io` файловых API.

---

### Этап 5 — Файлы и Векторы (5–7 дней)

#### 5.1. SupabaseArtifactStorage

```dart
class SupabaseArtifactStorage implements ArtifactStorage {
  // Supabase Storage API: https://supabase.com/docs/reference/javascript/storage
  // HTTP: POST /storage/v1/object/{bucket}/{key}
  // ...
}
```

#### 5.2. PgVectorStorage

```dart
class PgVectorStorage implements VectorStorage {
  // Supabase pgvector RPC:
  // CREATE FUNCTION match_documents(query_embedding vector(1536), ...)
  // Вызов: POST /rest/v1/rpc/match_documents
  // ...
}
```

#### 5.3. Переключить KnowledgeVault

```dart
KnowledgeVault(
  binaryStore: SupabaseArtifactStorage(bucket: 'documents'),
  vectorStorage: PgVectorStorage(supabaseUrl: '...'),
  metaStorage: SupabaseVaultStorage(...),
)
```

**Критерий:** индексация PDF работает, semantic search возвращает результаты.

---

### Этап 6 — Auth Service (5–7 дней)

**Цель:** Auth — отдельный сервис, тоже на dart_vault.

```
server_apps/aq_auth_service/
  lib/
    services/
      user_service.dart    ← vault.direct<User>(tenantId: 'auth')
      session_service.dart ← vault.logged<Session>(tenantId: 'auth')
```

Тот же `SupabaseVaultStorage` — другой `tenantId` = `auth`.  
Data Service принимает JWT от Auth Service.

**Критерий:** AQ Studio аутентифицируется через Auth Service.

---

### Этап 7 — Реалтайм + SSE (3–5 дней)

**Цель:** заменить polling на Server-Sent Events.

```dart
// В RemoteVaultStorage.watchChanges():
// GET /vault/watch?collection=alice__blueprints__nodes
// Accept: text/event-stream
//
// Server emits:
// data: {"event":"change","collection":"alice__blueprints__nodes"}
```

Нужно реализовать на сервере SSE endpoint и SSE клиент в RemoteVaultStorage.

**Критерий:** dashboard обновляется без перезагрузки.

---

## Схема синхронизации между клиентом и сервером

**Проблема:** domain-модели должны быть идентичны на клиенте и сервере.

**Решение:** shared пакет `pkgs/aq_schema` — единственный источник истины.

```
pkgs/
  aq_schema/
    lib/
      models/
        blueprint.dart     ← implements VersionedStorable
        workflow_run.dart  ← implements LoggedStorable
        project.dart       ← implements DirectStorable
        ...
      # Импортируется и Data Service, и Flutter client
```

**При добавлении нового поля:**
1. Добавить в `aq_schema` (с `required: false` или дефолтом)
2. Запустить миграцию Supabase: `ALTER TABLE ... ADD COLUMN ...`
3. Задеплоить Data Service
4. Задеплоить Flutter клиент

Если нарушить этот порядок → старый клиент не сломается (новое поле просто будет null).

---

## Шифрование

**Ответ: шифрование — ответственность пользователя пакета, не dart_vault.**

```dart
// Пример: шифрование ApiKey перед сохранением
final encrypted = aes256.encrypt(apiKey.rawValue, key: masterKey);
await repo.save(apiKey.withValue(encrypted), actorId: userId);

// Дешифрование при чтении
final raw = aes256.decrypt(found.value, key: masterKey);
```

dart_vault не знает о шифровании — это намеренно. Он работает с любыми байтами / строками.

---

## Сроки

| Этап | Дней | Риск |
|------|------|------|
| 0. Фундамент | 3–5 | Низкий |
| 1. Domain Models | 3–5 | Низкий |
| 2. Data Service API | 5–7 | Средний |
| 3. Миграция данных | 3–5 | **Высокий** |
| 4. Flutter Client | 7–10 | **Высокий** |
| 5. Файлы + Векторы | 5–7 | Средний |
| 6. Auth Service | 5–7 | Средний |
| 7. Realtime SSE | 3–5 | Низкий |
| **Итого** | **34–51 дней** | |

---

## Чеклист перед каждым деплоем

- [ ] `dart test` — все тесты зелёные
- [ ] `dart analyze` — 0 предупреждений
- [ ] Feature flag для нового функционала создан и задокументирован
- [ ] Миграция Supabase (если нужна) выполнена на staging первой
- [ ] Rollback-план описан (как вернуться к предыдущей версии)
- [ ] Мониторинг: логи Data Service не показывают VaultStorageException

---

*Документ основан на анализе кодовой базы AQ Studio (dump v993 файлов),  
архитектурных принципах из data_layer_arch.md и MCP_protocol_rules.md.*
