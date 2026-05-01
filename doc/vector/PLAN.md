# Vector Search Layer — Implementation Plan

**Версия:** 1.0  
**Дата:** 2026-05-01  
**Архитектура:** doc/vector/ARCHITECTURE.md  

---

## Принципы плана

- Каждый этап заканчивается **запускаемым сценарием** — не просто компилируется, а реально работает
- Каждый этап **не ломает** предыдущие сценарии (artifacts, security, stress)
- `dart analyze lib/ → 0 warnings` после каждого этапа
- Всё в памяти до Этапа 4 — никаких внешних зависимостей
- Mock-реализации достаточны для проверки механики

---

## Этап 0 — Подготовка: доработка существующего кода

**Цель:** Привести существующий VectorStorage и связанные классы в соответствие с архитектурой. Ничего нового не добавляем — только выравниваем.

### 0.1 Расширить VectorStorage интерфейс (aq_schema)

Файл: `aq_schema/lib/data_layer/storage/vector_storage.dart`

Добавить `tenantId` как обязательный параметр в `search()`:

```dart
Future<List<VectorSearchResult>> search(
  String collection,
  List<double> queryVector, {
  required String tenantId,   // ← добавить
  int limit = 10,
  double scoreThreshold = 0.0,
  VaultQuery? filter,
  String metric = 'cosine',   // ← добавить
});
```

Обновить `InMemoryVectorStorage.search()` — добавить фильтрацию по tenantId из payload.

### 0.2 Добавить IndexingStatus в StoredArtifact (aq_schema)

Файл: `aq_schema/lib/data_layer/storable/stored_artifact.dart`

```dart
enum IndexingStatus { none, pending, indexing, indexed, failed, stale }

// Добавить поля:
final IndexingStatus indexingStatus;  // default: IndexingStatus.none
final String? indexingError;
final String? indexedStoreId;
final int? chunkCount;
final DateTime? indexedAt;
```

Обновить `toMap()`, `fromMap()`, `kJsonSchema`.

### 0.3 Добавить новые модели данных (aq_schema)

Новые файлы в `aq_schema/lib/data_layer/vector/`:

```
vector/
  chunk_span.dart           — ChunkSpan
  pipeline_stamp.dart       — PipelineStamp
  extracted_content.dart    — ExtractedContent (in-memory)
  content_chunk.dart        — ContentChunk (in-memory)
  vector_point_payload.dart — VectorPointPayload (типизированный payload)
  indexing_result.dart      — IndexingResult
```

### 0.4 Добавить интерфейсы pipeline (aq_schema)

Новые файлы в `aq_schema/lib/data_layer/pipeline/`:

```
pipeline/
  i_content_extractor.dart
  i_modality_transformer.dart
  i_chunker.dart
  i_embeddings_client.dart
  i_reranker.dart
  i_vector_store_registry.dart
  vector_store_descriptor.dart
  indexing_pipeline.dart
```

### 0.5 Добавить справочные модели (aq_schema)

Новые файлы в `aq_schema/lib/data_layer/storable/`:

```
storable/
  indexing_pipeline_record.dart  — DirectStorable
  vector_store_record.dart       — DirectStorable
```

Добавить в `AqDomains.all`.

### 0.6 Обновить экспорты (aq_schema)

Файл: `aq_schema/lib/aq_schema.dart` — добавить все новые экспорты.

### Проверка Этапа 0

```bash
cd aq_data_layer && dart analyze lib/
# → 0 errors, 0 warnings

# Существующие сценарии не сломаны:
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-artifacts
# → 6 passed, 0 failed
```

---

## Этап 1 — Mock Pipeline: механика без реальных эмбеддингов

**Цель:** Полный pipeline от файла до векторного поиска, всё в памяти, эмбеддинги — mock.

### 1.1 MockEmbeddingsClient (aq_data_layer)

Файл: `aq_data_layer/lib/vector/mock_embeddings_client.dart`

```dart
final class MockEmbeddingsClient implements IEmbeddingsClient {
  final String id = 'mock-v1';
  final String version = '1';
  final int dimensions;
  final String defaultMetric = 'cosine';

  MockEmbeddingsClient({this.dimensions = 8});

  @override
  Future<List<double>> embed(String text) async {
    // Детерминированный вектор из хэша текста
    // Одинаковый текст → одинаковый вектор
    final hash = text.hashCode;
    final rng = Random(hash);
    final v = List.generate(dimensions, (_) => rng.nextDouble() * 2 - 1);
    return _normalize(v);
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) =>
      Future.wait(texts.map(embed));
}
```

**Почему детерминированный:** тесты стабильны, "похожие" тексты дают воспроизводимые результаты.

### 1.2 MockChunker (aq_data_layer)

Файл: `aq_data_layer/lib/vector/mock_chunker.dart`

```dart
final class MockChunker implements IChunker {
  final String id = 'mock-chunker-v1';
  final String version = '1';
  final int maxChunkSize;

  MockChunker({this.maxChunkSize = 200});

  @override
  List<ContentChunk> chunk(ExtractedContent content) {
    final text = content.text;
    final chunks = <ContentChunk>[];
    var start = 0;
    var index = 0;
    while (start < text.length) {
      final end = (start + maxChunkSize).clamp(0, text.length);
      chunks.add(ContentChunk(
        artifactId: content.artifactId,
        text: text.substring(start, end),
        span: ChunkSpan(
          chunkIndex: index++,
          startOffset: start,
          endOffset: end,
        ),
      ));
      start = end;
    }
    return chunks;
  }
}
```

### 1.3 PlainTextExtractor (aq_data_layer)

Файл: `aq_data_layer/lib/vector/plain_text_extractor.dart`

```dart
final class PlainTextExtractor implements IContentExtractor {
  final String id = 'plain-text-v1';
  final String version = '1';
  final Set<String> supportedContentTypes = {
    'text/plain', 'text/markdown', 'text/html',
  };

  @override
  Future<ExtractedContent> extract(
    List<int> bytes, String contentType, Map<String, dynamic> meta,
  ) async {
    return ExtractedContent(
      artifactId: meta['artifactId'] as String,
      tenantId: meta['tenantId'] as String,
      ownerId: meta['ownerId'] as String,
      modality: 'text',
      text: utf8.decode(bytes),
      meta: meta,
    );
  }
}
```

### 1.4 PassthroughReranker (aq_data_layer)

Файл: `aq_data_layer/lib/vector/passthrough_reranker.dart`

```dart
final class PassthroughReranker implements IReranker {
  final String id = 'passthrough-v1';

  @override
  Future<List<VectorSearchResult>> rerank(
    String query, List<VectorSearchResult> candidates,
  ) async => candidates;
}
```

### 1.5 VectorStoreRegistryImpl (aq_data_layer)

Файл: `aq_data_layer/lib/vector/vector_store_registry_impl.dart`

```dart
final class VectorStoreRegistryImpl implements IVectorStoreRegistry {
  final _stores = <String, (VectorStoreDescriptor, VectorStorage)>{};

  @override
  void register(VectorStoreDescriptor descriptor, VectorStorage storage) {
    _stores[descriptor.id] = (descriptor, storage);
  }

  @override
  VectorStorage resolve(String storeId) {
    final entry = _stores[storeId];
    if (entry == null) throw StateError('VectorStore not found: $storeId');
    return entry.$2;
  }

  @override
  VectorStoreDescriptor descriptor(String storeId) => _stores[storeId]!.$1;

  @override
  List<VectorStoreDescriptor> get all => _stores.values.map((e) => e.$1).toList();

  @override
  VectorStoreDescriptor? findCompatible(String embedderId, int vectorDim) =>
      all.where((d) => d.embedderId == embedderId && d.vectorDim == vectorDim)
         .firstOrNull;
}
```

### 1.6 VectorRepositoryImpl — переработать (aq_data_layer)

Файл: `aq_data_layer/lib/storage/vector_repository_impl.dart`

Текущая реализация — тонкая обёртка над VectorStorage. Нужно добавить:
- `index()` — полный pipeline: extract → chunk → embed → upsert
- `reindex()` — deleteDocument + index
- `search()` — embed query → storage.search → rerank
- `deleteDocument()` — deleteWhere по artifactId

```dart
final class VectorRepositoryImpl implements VectorRepository {
  final IVectorStoreRegistry _registry;
  final DirectRepository<StoredArtifact> _artifactRepo; // для обновления статуса

  Future<IndexingResult> index(
    StoredArtifact artifact,
    List<int> bytes,
    IndexingPipeline pipeline,
  ) async {
    final stopwatch = Stopwatch()..start();
    final storage = _registry.resolve(pipeline.storeId);

    // 1. Extract
    final content = await pipeline.extractor.extract(bytes, artifact.contentType, {
      'artifactId': artifact.id,
      'tenantId': artifact.tenantId,
      'ownerId': artifact.ownerId,
    });

    // 2. Transform (optional)
    final transformed = pipeline.transformer != null
        ? await pipeline.transformer!.transform(content)
        : content;

    // 3. Chunk
    final chunks = pipeline.chunker.chunk(transformed);

    // 4. Embed (batch)
    final vectors = await pipeline.embedder.embedBatch(
      chunks.map((c) => c.text).toList(),
    );

    // 5. Build VectorPoints
    final stamp = pipeline.buildStamp();
    final points = List.generate(chunks.length, (i) => VectorEntry(
      id: '${artifact.id}__chunk-$i',
      vector: vectors[i],
      payload: VectorPointPayload(
        tenantId: artifact.tenantId,
        ownerId: artifact.ownerId,
        artifactId: artifact.id,
        storeId: pipeline.storeId,
        modality: transformed.modality,
        span: chunks[i].span,
        text: chunks[i].text,
        stamp: stamp,
      ).toMap(),
    ));

    // 6. Upsert
    final collection = '${artifact.tenantId}__vectors';
    await storage.ensureCollection(collection, vectorSize: pipeline.embedder.dimensions);
    await storage.upsertAll(collection, points);

    stopwatch.stop();
    return IndexingResult(
      artifactId: artifact.id,
      chunksCreated: points.length,
      elapsed: stopwatch.elapsed,
      stamp: stamp,
    );
  }
}
```

### 1.7 Сценарий main_vector.dart

Файл: `example/stack/console_client/main_vector.dart`

```
Сценарий 1: Index — загрузить текст, проиндексировать (mock pipeline)
Сценарий 2: Search — найти топ-3 чанка по запросу
Сценарий 3: Filter — поиск только в одном артефакте
Сценарий 4: Reindex — изменить текст, переиндексировать
Сценарий 5: Delete — удалить чанки артефакта, убедиться что поиск пуст
Сценарий 6: Multi-tenant — два тенанта, изоляция поиска
```

### Проверка Этапа 1

```bash
# Собрать и запустить
docker-compose build --no-cache artifacts  # убедиться что artifacts не сломан
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-vector
# → 6 passed, 0 failed

dart analyze lib/
# → 0 errors, 0 warnings
```

---

## Этап 2 — Справочники: pipeline и store records в БД

**Цель:** Сохранять конфигурацию pipeline и store в PostgreSQL. UI может читать что использовалось для индексации.

### 2.1 Добавить IndexingPipelineRecord и VectorStoreRecord в AqDomains.all

```dart
DomainDescriptor.direct(
  collection: IndexingPipelineRecord.kCollection,
  fromMap: IndexingPipelineRecord.fromMap,
  indexes: [
    VaultIndex(name: 'idx_pipeline_name', field: 'name'),
    VaultIndex(name: 'idx_pipeline_embedder', field: 'embedderId'),
  ],
),

DomainDescriptor.direct(
  collection: VectorStoreRecord.kCollection,
  fromMap: VectorStoreRecord.fromMap,
  indexes: [
    VaultIndex(name: 'idx_store_type', field: 'type'),
    VaultIndex(name: 'idx_store_active', field: 'isActive'),
  ],
),
```

### 2.2 Обновить VectorRepositoryImpl

При `index()` — сохранять `IndexingPipelineRecord` если не существует.  
При `index()` — обновлять `StoredArtifact.indexingStatus` → `indexed`.  
При ошибке — обновлять `StoredArtifact.indexingStatus` → `failed` + `indexingError`.

### 2.3 Расширить сценарий main_vector.dart

```
Сценарий 7: Pipeline record — проверить что pipeline сохранён в БД
Сценарий 8: Artifact status — проверить что StoredArtifact.indexingStatus = indexed
Сценарий 9: Failed indexing — передать неподдерживаемый contentType, проверить status = failed
```

### Проверка Этапа 2

```bash
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-vector
# → 9 passed, 0 failed

# Проверить в БД напрямую
docker exec stack-postgres-1 psql -U vault_user -d vault_db \
  -c "SELECT id, name, embedder_id FROM indexing_pipelines LIMIT 5;"
```

---

## Этап 3 — Интеграция с Artifacts: единый workflow

**Цель:** Загрузить файл через ArtifactStorage и сразу проиндексировать. Единый сценарий upload → index → search.

### 3.1 Обновить main_artifacts.dart

Добавить сценарий:
```
Сценарий 7: Upload + Index — загрузить markdown, сразу проиндексировать
Сценарий 8: Search after upload — найти по семантическому запросу
```

### 3.2 Сценарий main_knowledge.dart

Полный end-to-end:
```
1. Upload файла (markdown)
2. Index (mock pipeline)
3. Add user annotation (highlight)
4. Add LLM annotation (vectorRef с chunkId из результата поиска)
5. Search — найти чанки
6. Verify — аннотация ссылается на реальный chunkId
7. Delete artifact — проверить что чанки удалены
```

### Проверка Этапа 3

```bash
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-knowledge
# → 7 passed, 0 failed
```

---

## Этап 4 — PgVectorStorage: реальная векторная БД

**Цель:** Заменить InMemoryVectorStorage на pgvector. Все сценарии проходят без изменений.

### 4.1 Добавить pgvector в Docker

Файл: `example/stack/docker-compose.yml`

```yaml
postgres:
  image: pgvector/pgvector:pg15  # вместо postgres:15-alpine
```

### 4.2 PgVectorStorage (aq_data_layer)

Файл: `aq_data_layer/lib/storage/postgres/pg_vector_storage.dart`

```sql
-- Таблица для каждой коллекции
CREATE TABLE IF NOT EXISTS {collection} (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  vector vector({dim}),
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS {collection}_vector_idx
  ON {collection} USING ivfflat (vector vector_cosine_ops)
  WITH (lists = 100);

CREATE INDEX IF NOT EXISTS {collection}_tenant_idx
  ON {collection} (tenant_id);
```

Поиск:
```sql
SELECT id, payload,
  1 - (vector <=> $1::vector) AS score
FROM {collection}
WHERE tenant_id = $2
  AND 1 - (vector <=> $1::vector) >= $3
ORDER BY vector <=> $1::vector
LIMIT $4;
```

### 4.3 Обновить server/main.dart

```dart
final vectorStorage = PgVectorStorage(pool: pool);
// Передать в VectorStoreRegistryImpl
```

### 4.4 Запустить все сценарии

```bash
docker-compose build --no-cache
docker-compose up -d

docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-artifacts
# → 6 passed, 0 failed

docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-vector
# → 9 passed, 0 failed

docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-knowledge
# → 7 passed, 0 failed
```

---

## Этап 5 — Remote Vector Transport: RPC для векторных операций

**Цель:** Клиент работает с векторами через тот же RPC механизм что и с документами.

### 5.1 Добавить vector операции в VaultRegistry.dispatch()

```dart
// Новые операции:
// 'vectors/index'    — args: {artifactId, pipelineId}
// 'vectors/search'   — args: {query, storeId, topK, filter}
// 'vectors/delete'   — args: {artifactId, storeId}
// 'vectors/reindex'  — args: {artifactId, pipelineId}
```

### 5.2 RemoteVectorRepository (aq_data_layer)

Файл: `aq_data_layer/lib/client/remote/remote_vector_repository.dart`

Клиентская реализация VectorRepository через RPC. Аналогично RemoteArtifactStorage.

### 5.3 Экспортировать из dart_vault.dart

### Проверка Этапа 5

```bash
# Все предыдущие сценарии проходят через RPC
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 stack-vector
# → 9 passed, 0 failed
```

---

## Сводная таблица этапов

| Этап | Что делаем | Проверка | Зависимости |
|---|---|---|---|
| 0 | Модели, интерфейсы, IndexingStatus | analyze 0 warnings + artifacts сценарий | — |
| 1 | Mock pipeline, InMemory, main_vector.dart | 6 vector сценариев | Этап 0 |
| 2 | Справочники в БД, статус артефакта | 9 vector сценариев | Этап 1 |
| 3 | Интеграция artifacts + vectors | main_knowledge.dart 7 сценариев | Этап 2 |
| 4 | PgVectorStorage, pgvector Docker | Все сценарии на реальной БД | Этап 3 |
| 5 | Remote RPC transport | Все сценарии через RPC | Этап 4 |

---

## Файлы которые будут созданы/изменены

### aq_schema (изменения)

```
lib/data_layer/storage/vector_storage.dart          ИЗМЕНИТЬ (tenantId, metric)
lib/data_layer/storable/stored_artifact.dart        ИЗМЕНИТЬ (IndexingStatus)
lib/data_layer/vector/chunk_span.dart               СОЗДАТЬ
lib/data_layer/vector/pipeline_stamp.dart           СОЗДАТЬ
lib/data_layer/vector/extracted_content.dart        СОЗДАТЬ
lib/data_layer/vector/content_chunk.dart            СОЗДАТЬ
lib/data_layer/vector/vector_point_payload.dart     СОЗДАТЬ
lib/data_layer/vector/indexing_result.dart          СОЗДАТЬ
lib/data_layer/pipeline/i_content_extractor.dart    СОЗДАТЬ
lib/data_layer/pipeline/i_modality_transformer.dart СОЗДАТЬ
lib/data_layer/pipeline/i_chunker.dart              СОЗДАТЬ
lib/data_layer/pipeline/i_embeddings_client.dart    СОЗДАТЬ
lib/data_layer/pipeline/i_reranker.dart             СОЗДАТЬ
lib/data_layer/pipeline/i_vector_store_registry.dart СОЗДАТЬ
lib/data_layer/pipeline/vector_store_descriptor.dart СОЗДАТЬ
lib/data_layer/pipeline/indexing_pipeline.dart      СОЗДАТЬ
lib/data_layer/storable/indexing_pipeline_record.dart СОЗДАТЬ
lib/data_layer/storable/vector_store_record.dart    СОЗДАТЬ
lib/data_layer/aq_domains.dart                      ИЗМЕНИТЬ
lib/aq_schema.dart                                  ИЗМЕНИТЬ (экспорты)
```

### aq_data_layer (изменения)

```
lib/vector/mock_embeddings_client.dart              СОЗДАТЬ
lib/vector/mock_chunker.dart                        СОЗДАТЬ
lib/vector/plain_text_extractor.dart                СОЗДАТЬ
lib/vector/passthrough_reranker.dart                СОЗДАТЬ
lib/vector/vector_store_registry_impl.dart          СОЗДАТЬ
lib/storage/vector_repository_impl.dart             ПЕРЕРАБОТАТЬ
lib/storage/in_memory_vector_storage.dart           ИЗМЕНИТЬ (tenantId filter)
lib/storage/postgres/pg_vector_storage.dart         СОЗДАТЬ (Этап 4)
lib/client/remote/remote_vector_repository.dart     СОЗДАТЬ (Этап 5)
lib/dart_vault.dart                                 ИЗМЕНИТЬ (экспорты)
lib/server.dart                                     ИЗМЕНИТЬ (экспорты)
example/stack/server/main.dart                      ИЗМЕНИТЬ (vector registry)
example/stack/console_client/main_vector.dart       СОЗДАТЬ
example/stack/console_client/main_knowledge.dart    СОЗДАТЬ
example/stack/console_client/Dockerfile.vector      СОЗДАТЬ
example/stack/console_client/Dockerfile.knowledge   СОЗДАТЬ
example/stack/docker-compose.yml                    ИЗМЕНИТЬ (vector/knowledge сервисы)
```

---

## Начинаем с Этапа 0
