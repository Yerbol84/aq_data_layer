# Отчёт сессии — 2026-04-30

---

## Что сделано

### 1. Стресс-сценарии (Приоритет 1) ✅

Написаны и прошли 4 стресс-теста в `example/stack/console_client/main_stress.dart`:

- **Multi-tenant isolation** — `findById` и `findAll` не протекают между tenant. SQL фильтрует по `tenant_id` на уровне compiler.
- **Concurrent writes** — два клиента пишут одновременно, last-write-wins, без краша.
- **Versioned branching** — ветки независимы от main, double-publish корректно отклоняется.
- **Logged rollback chain** — 5 изменений → rollback → ещё 2 изменения, история корректна.

Файлы: `Dockerfile.stress`, запись в `docker-compose.yml`.

**Находка:** `listVersions` не возвращает branch-draft узлы — это поведение по дизайну, задокументировано в `PLAN.md`.

---

### 2. Security Gate (Приоритет 2) ✅

Интегрирован `IVaultSecurityProtocol` из `aq_schema` в data layer.

**Что изменено:**

| Файл | Изменение |
|---|---|
| `lib/deploy/vault_registry.dart` | `dispatch()` принимает `headers`, вызывает `IVaultSecurityProtocol` перед каждой операцией |
| `example/stack/server/main.dart` | HTTP headers передаются в `dispatch()`, `SECURITY_MODE=mock` включает `MockVaultSecurityProtocol` |
| `lib/client/vault.dart` | `Vault.remote()` принимает `authToken` |
| `lib/client/data_layer_impl.dart` | `DataLayerImpl.connect()` принимает `authToken` |
| `lib/dart_vault.dart` | `initializeDataLayer()` читает токен из `IAuthContext`, принимает `authToken` |

**Маппинг операций → действия** (`_operationToAction`):
- `get`, `query`, `findById`, `findAll`, `count`, ... → `read`
- `upsert`, `save`, `updateDraft`, ... → `write`
- `delete`, `deleteEntity` → `delete`
- `publishDraft` → `publish`
- `grantAccess` → `grant`

**Сценарии** в `main_security.dart` — все 4 прошли:
- Admin token → всё разрешено ✅
- Readonly token → read OK, write/delete denied ✅
- Blocked token → всё denied ✅
- Anonymous → write denied ✅

Файлы: `Dockerfile.security`, `server-secure` сервис в `docker-compose.yml`.

---

### 3. Технический долг ✅

- `supabase_vault_storage.dart` — исправлены `strict_raw_type`, `unnecessary_non_null_assertion`, убран `@internal`
- `VersionedStorageContract` — удалён (не было реальных usages), убран экспорт из `server.dart`
- `dart analyze lib/` — **0 errors, 0 warnings**

---

### 4. Artifacts + Annotations (Приоритет 3) — в процессе

**Сделано:**

| Файл | Что |
|---|---|
| `aq_schema/lib/data_layer/storable/stored_artifact.dart` | Конкретная реализация `ArtifactEntry` (DirectStorable) |
| `aq_schema/lib/data_layer/storable/document_annotation.dart` | `DocumentAnnotation` (LoggedStorable) + `AnnotationRange`, `AnnotationType`, `AnnotationActorType` |
| `aq_schema/lib/data_layer/aq_domains.dart` | Оба домена добавлены в `AqDomains.all` (9 доменов теперь) |
| `aq_schema/lib/aq_schema.dart` | Экспорты добавлены |
| `lib/deploy/vault_registry.dart` | `artifactBackend` параметр + обработка `uploadBytes`/`downloadBytes`/`deleteBytes`/`listBytes` |
| `lib/client/remote/remote_artifact_storage.dart` | `RemoteArtifactStorage` — клиентская реализация `ArtifactStorage` через RPC (base64) |

**Архитектура:**
```
ArtifactRepository
  ├── VaultStorage (метаданные StoredArtifact — Direct)
  └── ArtifactStorage (байты — Local/Remote/S3/Postgres)

DocumentAnnotation (LoggedStorable)
  └── artifactId → StoredArtifact.id
```

---

## Что осталось сделать

### Artifacts (продолжение)

- [ ] Написать `main_artifacts.dart` — сценарий: upload файла, добавить аннотации, найти по artifactId
- [ ] Добавить `LocalArtifactStorage` в сервер по умолчанию (сейчас `artifactBackend: null`)
- [ ] Экспортировать `RemoteArtifactStorage` из `dart_vault.dart`
- [ ] Добавить `ArtifactVault` в `IDataLayer` для удобного доступа

### Векторная БД (Приоритет 4)

- [ ] `IEmbeddingsClient` интерфейс в `aq_schema`
- [ ] `VectorChunk` модель (DirectStorable) + добавить в `AqDomains.all`
- [ ] `PostgresVectorRepository` — реальный pgvector бэкенд (сейчас только InMemory)
- [ ] `TextChunker` — разбивка текста на чанки
- [ ] `KnowledgePipeline` — файл → чанки → embeddings → VectorChunk

### Технический долг (остаток)

- [ ] Flutter client widget test сломан (smoke test не соответствует UI)
- [ ] `postgres_example.dart` — не входит в Docker стек

---

## Состояние пакета

```
dart analyze lib/  →  0 errors, 0 warnings
Сценарии:          →  все ✅ (scenarios, stress, security)
```

### Домены в AqDomains.all (9 штук)

| Домен | Режим |
|---|---|
| `AqStudioProject` | Direct |
| `WorkflowGraph` | Versioned |
| `InstructionGraph` | Versioned |
| `PromptGraph` | Versioned |
| `GraphRunState` | Direct |
| `WorkflowRun` | Logged |
| `TestDocumentV1` | Direct |
| `StoredArtifact` | Direct ← новый |
| `DocumentAnnotation` | Logged ← новый |
