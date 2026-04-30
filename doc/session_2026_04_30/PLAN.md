# AQ Data Layer — План развития

> Дата: 2026-04-30  
> Текущее состояние: Direct / Versioned / Logged работают, подтверждено тестами

---

## Что работает сейчас ✅

- **Direct** — CRUD, soft delete, restore, фильтрация, пагинация
- **Versioned** — draft → publish, ветки, доступ (grant/revoke), listVersions
- **Logged** — audit trail, diff, rollback, soft delete с сохранением лога
- **Мультитенантность** — изоляция по tenantId на уровне SQL
- **Два режима** — serverless (InMemory) и client-server (PostgreSQL + RPC)
- **Typed transport** — sendCommand / sendQuery вместо raw RPC
- **IDataLayer.initialize()** — единая точка инициализации

---

## Приоритет 1 — Сложные сценарии (обкатка реальности)

Текущие примеры покрывают happy path. Нужны стресс-сценарии:

### 1.1 Multi-tenant изоляция
- Два tenant пишут в одну коллекцию одновременно
- Проверить что tenant A не видит данные tenant B
- Проверить что фильтры не "протекают" между tenant

### 1.2 Concurrent writes
- Два клиента обновляют одну запись одновременно
- Ожидаемое поведение: последний выигрывает (last-write-wins)
- Для Versioned: нельзя публиковать уже опубликованный draft

### 1.3 Error recovery
- Сервер падает в середине транзакции
- Клиент с буфером: данные не теряются, flush при reconnect
- Logged: частичная запись не должна оставлять orphan log entries

### 1.4 Versioned branching
- Создать ветку от published версии
- Опубликовать ветку
- Проверить что main и branch независимы

### 1.5 Logged rollback chain
- 5 изменений → rollback к шагу 3 → ещё 2 изменения
- История должна отражать rollback как отдельную операцию

---

## Приоритет 2 — Security Gate

### Концепция

Два режима, переключаются при инициализации:

```dart
// Режим без защиты (dev, internal services)
await IDataLayer.initialize(endpoint: '...');

// Режим с защитой (production)
await IDataLayer.initialize(
  endpoint: '...',
  securityEndpoint: 'http://security-service:9000',
);
```

### Интерфейс (в aq_schema)

```dart
abstract interface class ISecurityGate {
  // Бросает SecurityException если запрещено
  Future<void> checkRead(SecurityContext ctx, String collection, String? ownerId);
  Future<void> checkWrite(SecurityContext ctx, String collection, String? ownerId);
  Future<void> checkDelete(SecurityContext ctx, String collection, String? ownerId);
}

class SecurityContext {
  final String tenantId;
  final String actorId;
  final List<String> roles;
}

// Passthrough — всё разрешено (dev/internal)
class NoopSecurityGate implements ISecurityGate { ... }

// Remote — делегирует в security service
class RemoteSecurityGate implements ISecurityGate { ... }
```

### Что нужно добавить в модели

- `ownerId` уже есть в большинстве доменов
- Нужен `SecurityContext` в каждом вызове репозитория (опционально, через ambient context)

---

## Приоритет 3 — Файловое хранилище (Artifacts)

Скелет уже есть (`ArtifactStorage`, `ArtifactRepository`), нужно:

### 3.1 Remote artifact transport
- `sendCommand('uploadArtifact', {bytes, mimeType, name})`
- `sendQuery('downloadArtifact', {artifactId})`
- Сервер: хранить в PostgreSQL (bytea) или S3-совместимом хранилище

### 3.2 Привязка к доменам
- `ArtifactEntry` — ссылка на файл из любого домена
- `WorkflowGraph` может иметь прикреплённые файлы

### 3.3 Поддерживаемые форматы (v1)
- PDF, Markdown, исходный код (text/*)
- Бинарные файлы (image/*, application/*)

---

## Приоритет 4 — Векторная БД (Knowledge Base)

### Концепция

Файл → чанки → embeddings → векторы → поиск по смыслу

```
PDF/MD/Code
    ↓ chunker
[chunk1, chunk2, ...]
    ↓ embeddings client (OpenAI / local)
[vector1, vector2, ...]
    ↓ VectorRepository
pgvector (PostgreSQL extension)
    ↓ similarity search
Релевантные чанки для LLM контекста
```

### Что нужно

- `pgvector` extension в PostgreSQL
- `VectorRepository.upsert(embedding)` — уже есть интерфейс
- `VectorRepository.search(query, topK)` — уже есть интерфейс
- `PostgresVectorRepository` — реальный бэкенд (сейчас только InMemory)
- `FileChunker` — разбивка файла на чанки
- `IEmbeddingsClient` — интерфейс для получения embeddings (OpenAI / local)
- `KnowledgeRepository` — pipeline: файл → векторы

### Тенантность

Каждый вектор содержит `tenantId` — изоляция как в остальных репозиториях.

---

## Порядок работы

```
[сейчас]  Сложные сценарии → найти и исправить баги в Direct/Versioned/Logged
[потом]   ISecurityGate → passthrough + remote режимы
[потом]   Remote artifact storage → PostgreSQL bytea backend
[потом]   pgvector backend → реальный VectorRepository
[потом]   FileChunker + IEmbeddingsClient → KnowledgeRepository pipeline
```

---

## Технический долг

- `supabase_vault_storage.dart` — warnings (strict_raw_type, unnecessary_non_null_assertion)
- `VersionedStorageContract` — помечен `@Deprecated`, нужно удалить после миграции
- Flutter client (`example/stack/flutter_client`) — widget test сломан (smoke test не соответствует UI)
- `postgres_example.dart` — требует локальный PostgreSQL, не входит в Docker стек
