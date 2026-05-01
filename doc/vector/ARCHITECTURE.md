# Vector Search Layer — Architecture

**Версия:** 1.0  
**Дата:** 2026-05-01  
**Статус:** Approved  

---

## 1. Контекст и цели

### Место в системе

`aq_data_layer` уже имеет три слоя хранения:
- **VaultStorage** — документы (direct / versioned / logged)
- **ArtifactStorage** — бинарные файлы (байты)
- **VectorStorage** — векторные эмбеддинги (ANN-поиск) ← **этот документ**

Векторный слой принципиально отличается от первых двух: его основная операция — не CRUD, а **similarity search** (поиск ближайших соседей в многомерном пространстве). Поэтому он реализован как независимый интерфейс, а не расширение VaultStorage.

### Цели

1. Семантический поиск по любому контенту (текст, изображения, аудио, видео)
2. Полная независимость от конкретной векторной БД
3. Поддержка нескольких хранилищ одновременно (multi-store)
4. Воспроизводимость: каждый чанк знает как он был создан (data lineage)
5. Мультитенантность и изоляция владельца на уровне интерфейса
6. Модульность: отсутствующие компоненты игнорируются, не ломают систему

---

## 2. Принципы архитектуры

| Принцип | Применение |
|---|---|
| **Interface segregation** | Каждый инструмент pipeline — отдельный интерфейс |
| **Dependency inversion** | Все зависимости направлены к интерфейсам в aq_schema |
| **Open/Closed** | Новая БД = новая реализация VectorStorage, ничего не меняется |
| **Fail-safe defaults** | InMemory по умолчанию везде, система работает без внешних зависимостей |
| **Data lineage** | Каждый VectorPoint несёт PipelineStamp — полную историю создания |
| **Tenant-first** | tenantId обязательный параметр search(), не опциональный |

---

## 3. Обзор слоёв

```
┌─────────────────────────────────────────────────────────────┐
│                    Приложение / Сценарий                     │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              VectorRepository (aq_data_layer)                │
│   index() · reindex() · search() · deleteDocument()         │
│   Оркестратор: связывает pipeline + storage                  │
└───┬──────────────┬──────────────┬───────────────────────────┘
    │              │              │
    ▼              ▼              ▼
IContentExtractor  IChunker  IEmbeddingsClient
(извлечение)    (разбивка)   (векторизация)
    │              │              │
    └──────────────┴──────────────┘
                   │
         IndexingPipeline
         (конфигурация)
                   │
┌──────────────────▼──────────────────────────────────────────┐
│              VectorStorage (интерфейс, aq_schema)            │
│   upsert · search · deleteWhere · ensureCollection          │
└───┬──────────────┬──────────────┬───────────────────────────┘
    │              │              │
    ▼              ▼              ▼
InMemory      PgVector        Qdrant
(default)    (production)   (future)
```

---

## 4. Модели данных (aq_schema)

### 4.1 VectorPoint — единица хранения

```dart
final class VectorPoint {
  final String id;              // uuid, уникален в пределах store
  final List<double> vector;    // эмбеддинг
  final VectorPointPayload payload;
}
```

**Решение:** payload — типизированный класс, не `Map<String, dynamic>`.  
**Обоснование:** Map не даёт автодополнения, рефакторинга, статической проверки. При росте системы Map превращается в неуправляемый мешок. Типизированный payload — единственный правильный выбор для production.

### 4.2 VectorPointPayload — контекст чанка

```dart
final class VectorPointPayload {
  // Тенантность — обязательно, проверяется при поиске
  final String tenantId;
  final String ownerId;

  // Ссылка на оригинал
  final String artifactId;      // StoredArtifact.id
  final String storeId;         // VectorStoreDescriptor.id — откуда запись
  final String modality;        // 'text' | 'image' | 'audio' | 'video'

  // Позиция в оригинале (зависит от модальности)
  final ChunkSpan span;

  // Содержимое (для отображения без обращения к оригиналу)
  final String text;            // текст чанка или транскрипция

  // Lineage — как был создан
  final PipelineStamp stamp;
}
```

**Решение:** `storeId` в каждом чанке.  
**Обоснование:** При наличии нескольких хранилищ (pgvector для текста, Qdrant для изображений) система должна знать откуда запись. При миграции старые чанки указывают на старое хранилище — они не теряются, просто используют свой store.

### 4.3 ChunkSpan — позиция в оригинале

```dart
final class ChunkSpan {
  final int chunkIndex;         // порядковый номер чанка
  final int? startOffset;       // текст: символьный offset
  final int? endOffset;
  final double? startTime;      // аудио/видео: секунды
  final double? endTime;
  final int? pageNumber;        // PDF: номер страницы
  final int? frameIndex;        // видео: номер кадра
}
```

**Решение:** Все поля nullable, только `chunkIndex` обязателен.  
**Обоснование:** Разные модальности имеют разные координаты. Принудительные поля для всех модальностей создали бы фиктивные значения. Nullable + chunkIndex как минимальный общий знаменатель.

### 4.4 PipelineStamp — data lineage

```dart
final class PipelineStamp {
  final String extractorId;       // 'plain-text-v1', 'pdf-pdfium-v2'
  final String extractorVersion;
  final String? transformerId;    // null если не нужен (plain text)
  final String? transformerVersion;
  final String chunkerId;         // 'sentence-splitter-v1', 'fixed-512-v1'
  final String chunkerVersion;
  final String embedderId;        // 'openai-ada-002', 'mock-v1'
  final String embedderVersion;
  final int vectorDim;            // 1536, 768, etc.
  final String metric;            // 'cosine', 'dot', 'euclidean'
  final DateTime indexedAt;
}
```

**Решение:** Stamp записывается в каждый чанк, не только в метаданные документа.  
**Обоснование:** При поиске нужно фильтровать по `embedderId` — query-вектор должен быть из того же пространства что и stored-векторы. Если stamp только в документе, нужен join. Если в каждом чанке — один запрос.

**Практика:** Pinecone рекомендует namespace per model version. Weaviate использует class per schema version. Мы используем stamp в payload + фильтрацию — более гибко, не требует отдельных коллекций.

### 4.5 VectorSearchResult

```dart
final class VectorSearchResult {
  final String id;
  final double score;             // 0..1, cosine similarity
  final VectorPointPayload payload;
}
```

**Решение:** payload типизированный, не Map.  
**Обоснование:** Клиент должен получить структурированный результат, а не парсить Map.

### 4.6 Промежуточные модели (in-memory, не хранятся в БД)

```dart
// После извлечения из файла
final class ExtractedContent {
  final String artifactId;
  final String tenantId;
  final String ownerId;
  final String modality;
  final String text;              // текст или транскрипция
  final Map<String, dynamic> meta; // pageCount, duration, dimensions
}

// После разбивки на чанки
final class ContentChunk {
  final String artifactId;
  final String text;
  final ChunkSpan span;
}
```

**Решение:** Промежуточные модели не реализуют Storable, не попадают в БД.  
**Обоснование:** LlamaIndex, LangChain — оба используют промежуточный Document. Без него IChunker получает сырые байты и должен знать формат файла — нарушение SRP. Extractor знает формат, Chunker знает только текст.

---

## 5. Справочные модели (хранятся в VaultStorage)

Некоторые сущности нужно хранить как справочники — для аудита, воспроизведения, UI.

### 5.1 IndexingPipelineRecord — DirectStorable

```dart
final class IndexingPipelineRecord implements DirectStorable {
  static const kCollection = 'indexing_pipelines';

  final String id;
  final String name;              // 'default-text', 'pdf-openai'
  final String extractorId;
  final String extractorVersion;
  final String? transformerId;
  final String? transformerVersion;
  final String chunkerId;
  final String chunkerVersion;
  final String embedderId;
  final String embedderVersion;
  final int vectorDim;
  final String metric;
  final String storeId;           // целевое хранилище
  final bool isDefault;
  final DateTime createdAt;
}
```

**Решение:** DirectStorable (не versioned, не logged).  
**Обоснование:** Pipeline — конфигурация, не документ с историей. Если нужна новая версия — создаётся новая запись с новым id. Старые чанки ссылаются на старый pipeline через stamp.

### 5.2 VectorStoreRecord — DirectStorable

```dart
final class VectorStoreRecord implements DirectStorable {
  static const kCollection = 'vector_stores';

  final String id;                // 'pgvector-main', 'qdrant-docs'
  final String type;              // 'pgvector' | 'qdrant' | 'in_memory'
  final String embedderId;        // совместимый embedder
  final int vectorDim;
  final String metric;
  final Map<String, String> config; // endpoint, collection, etc. (без секретов)
  final bool isActive;
  final DateTime createdAt;
}
```

**Решение:** DirectStorable, config без секретов.  
**Обоснование:** Секреты (API keys, passwords) — в environment variables или secrets manager, не в БД. В config только публичные параметры: endpoint, collection name, region.

### 5.3 ArtifactIndexingStatus — добавить в StoredArtifact

```dart
enum IndexingStatus { none, pending, indexing, indexed, failed, stale }

// Добавить поля в StoredArtifact:
final IndexingStatus indexingStatus;  // default: none
final String? indexingError;          // если failed
final String? indexedStoreId;         // в каком store проиндексирован
final int? chunkCount;                // сколько чанков создано
final DateTime? indexedAt;            // когда проиндексирован
```

**Решение:** Статус индексации в StoredArtifact, не в отдельной таблице.  
**Обоснование:** Haystack, LlamaIndex — оба хранят indexing status в document record. Отдельная таблица создаёт join при каждом запросе списка документов. Денормализация оправдана — статус меняется редко, читается часто.

---

## 6. Интерфейсы pipeline (aq_schema)

### 6.1 IContentExtractor

```dart
abstract interface class IContentExtractor {
  String get id;
  String get version;
  Set<String> get supportedContentTypes; // {'application/pdf', 'text/plain'}

  Future<ExtractedContent> extract(
    List<int> bytes,
    String contentType,
    Map<String, dynamic> meta,
  );
}
```

**Ответственность:** Только извлечение контента из байт. Не знает о чанках, не знает об эмбеддингах.

**Реализации:**
- `PlainTextExtractor` — `text/*` → текст как есть
- `PdfExtractor` — PDF → текст постранично (future)
- `MockExtractor` — возвращает фиксированный текст (тесты)

### 6.2 IModalityTransformer

```dart
abstract interface class IModalityTransformer {
  String get id;
  String get version;
  String get inputModality;   // 'audio', 'video', 'image'
  String get outputModality;  // обычно 'text'

  Future<ExtractedContent> transform(ExtractedContent input);
}
```

**Ответственность:** Преобразование модальности. Аудио→текст (Whisper), изображение→caption (CLIP/GPT-4V), видео→транскрипт.

**Решение:** Опциональный шаг в pipeline. Если `transformer == null` — шаг пропускается.  
**Обоснование:** Для plain text трансформация не нужна. Принудительный transformer для всех модальностей создал бы no-op реализации.

### 6.3 IChunker

```dart
abstract interface class IChunker {
  String get id;
  String get version;

  List<ContentChunk> chunk(ExtractedContent content);
}
```

**Ответственность:** Разбивка текста на чанки с сохранением позиции (ChunkSpan).

**Реализации:**
- `FixedSizeChunker` — фиксированный размер с overlap (уже есть как FixedSizeSplitter)
- `SentenceChunker` — по предложениям (future)
- `MockChunker` — возвращает один чанк = весь текст (тесты)

### 6.4 IEmbeddingsClient

```dart
abstract interface class IEmbeddingsClient {
  String get id;
  String get version;
  int get dimensions;
  String get defaultMetric;   // 'cosine'

  Future<List<double>> embed(String text);
  Future<List<List<double>>> embedBatch(List<String> texts);
}
```

**Решение:** `embedBatch` обязателен в интерфейсе.  
**Обоснование:** OpenAI API имеет rate limits и стоимость per-token. Батч-запрос в 100 раз эффективнее 100 одиночных. Если не заложить в интерфейс — каждая реализация будет делать по-своему.

**Реализации:**
- `MockEmbeddingsClient` — детерминированные псевдо-векторы (тесты)
- `OpenAiEmbeddingsClient` — OpenAI ada-002 (future)

### 6.5 IReranker

```dart
abstract interface class IReranker {
  String get id;

  Future<List<VectorSearchResult>> rerank(
    String query,
    List<VectorSearchResult> candidates,
  );
}
```

**Решение:** Интерфейс заложен, реализация — future.  
**Обоснование:** Reranker (Cohere Rerank, BGE-reranker) значительно улучшает качество RAG. Не заложить интерфейс сейчас — значит переписывать VectorRepository позже.

**Реализации:**
- `PassthroughReranker` — возвращает candidates без изменений (default)

---

## 7. VectorStorage интерфейс (aq_schema)

```dart
abstract interface class VectorStorage {
  // Управление коллекциями
  Future<void> ensureCollection(String collection, {
    required int vectorSize,
    String distance = 'cosine',
  });
  Future<void> deleteCollection(String collection);

  // Запись
  Future<void> upsert(String collection, VectorEntry entry);
  Future<void> upsertAll(String collection, List<VectorEntry> entries);
  Future<void> delete(String collection, String id);
  Future<void> deleteWhere(String collection, VaultQuery filter);

  // Поиск — tenantId обязателен
  Future<List<VectorSearchResult>> search(
    String collection,
    List<double> queryVector, {
    required String tenantId,
    int limit = 10,
    double scoreThreshold = 0.0,
    VaultQuery? filter,
    String metric = 'cosine',
  });

  // Чтение
  Future<VectorEntry?> getById(String collection, String id);
  Future<List<VectorEntry>> getAll(String collection, {VaultQuery? filter});
  Future<int> count(String collection, {VaultQuery? filter});

  Future<void> dispose();
}
```

**Решение:** `tenantId` — обязательный named parameter в `search()`.  
**Обоснование:** Если tenantId опциональный — разработчик может забыть его передать и получить данные чужого тенанта. Компилятор должен это предотвращать. Это не удобство — это безопасность.

**Решение:** `metric` параметр в search().  
**Обоснование:** Разные use cases требуют разных метрик. Текст — cosine. Рекомендации — dot product (быстрее при нормализованных векторах). Временные ряды — euclidean. Интерфейс не должен ограничивать.

---

## 8. IVectorStoreRegistry (aq_schema)

```dart
abstract interface class IVectorStoreRegistry {
  void register(VectorStoreDescriptor descriptor, VectorStorage storage);
  VectorStorage resolve(String storeId);
  VectorStoreDescriptor descriptor(String storeId);
  List<VectorStoreDescriptor> get all;
  VectorStoreDescriptor? findCompatible(String embedderId, int vectorDim);
}

final class VectorStoreDescriptor {
  final String id;          // 'pgvector-main', 'memory-default'
  final String type;        // 'pgvector' | 'qdrant' | 'in_memory'
  final String embedderId;  // совместимый embedder
  final int vectorDim;
  final String metric;
  final bool isDefault;
}
```

**Решение:** Реестр хранилищ как отдельная концепция.  
**Обоснование:** При нескольких хранилищах (текст в pgvector, изображения в Qdrant) нужен центральный реестр. VectorRepository получает storeId и резолвит через реестр. Это также позволяет runtime-переключение хранилищ без перезапуска.

---

## 9. IndexingPipeline (aq_schema)

```dart
final class IndexingPipeline {
  final String id;                          // ссылка на IndexingPipelineRecord
  final String storeId;                     // целевое хранилище
  final IContentExtractor extractor;
  final IModalityTransformer? transformer;  // null для plain text
  final IChunker chunker;
  final IEmbeddingsClient embedder;
  final IReranker reranker;                 // default: PassthroughReranker

  PipelineStamp buildStamp() => PipelineStamp(
    extractorId: extractor.id,
    extractorVersion: extractor.version,
    transformerId: transformer?.id,
    transformerVersion: transformer?.version,
    chunkerId: chunker.id,
    chunkerVersion: chunker.version,
    embedderId: embedder.id,
    embedderVersion: embedder.version,
    vectorDim: embedder.dimensions,
    metric: embedder.defaultMetric,
    indexedAt: DateTime.now().toUtc(),
  );
}
```

---

## 10. VectorRepository (aq_data_layer)

```dart
abstract interface class VectorRepository {
  Future<IndexingResult> index(
    StoredArtifact artifact,
    List<int> bytes,
    IndexingPipeline pipeline,
  );

  Future<IndexingResult> reindex(
    StoredArtifact artifact,
    List<int> bytes,
    IndexingPipeline pipeline,
  );

  Future<List<VectorSearchResult>> search(
    String query, {
    required String tenantId,
    required String storeId,
    int topK = 10,
    String? artifactId,
    String? ownerId,
    double scoreThreshold = 0.0,
    IReranker? reranker,
  });

  Future<void> deleteDocument(String artifactId, String storeId);
}

final class IndexingResult {
  final String artifactId;
  final int chunksCreated;
  final Duration elapsed;
  final PipelineStamp stamp;
  final String? error;          // null если успех
}
```

**Решение:** `index()` возвращает `IndexingResult`, не `void`.  
**Обоснование:** Клиент должен знать сколько чанков создано, сколько времени заняло, какой stamp использован. Это нужно для обновления `StoredArtifact.indexingStatus` и для отладки.

---

## 11. Реализации (aq_data_layer)

### 11.1 InMemoryVectorStorage

Уже реализован. Brute-force cosine similarity. O(n·d). Подходит для dev/test и малых корпусов (< 10k векторов).

**Изменение:** добавить `tenantId` фильтрацию в `search()` как обязательный шаг.

### 11.2 PgVectorStorage (future)

```
PostgreSQL + pgvector extension
Индекс: ivfflat (cosine_ops)
Таблица: vector_chunks (id, collection, tenant_id, vector vector(N), payload jsonb)
Поиск: SELECT ... ORDER BY vector <=> $1 WHERE tenant_id = $2 LIMIT $3
```

### 11.3 QdrantVectorStorage (future)

```
Qdrant HTTP API
Collection per store
Payload filter: {"must": [{"key": "tenantId", "match": {"value": "..."}}]}
HNSW index — быстрее ivfflat при > 1M векторов
```

### 11.4 MockEmbeddingsClient

```dart
final class MockEmbeddingsClient implements IEmbeddingsClient {
  final String id = 'mock-v1';
  final String version = '1';
  final int dimensions;
  final String defaultMetric = 'cosine';

  // Детерминированный вектор из хэша текста
  // Одинаковый текст → одинаковый вектор
  // Разный текст → разные векторы (с высокой вероятностью)
}
```

**Решение:** Детерминированный mock, не случайный.  
**Обоснование:** Случайные векторы делают тесты нестабильными. Детерминированный mock из хэша текста позволяет проверять что "похожие тексты дают похожие результаты" — даже в тестах.

### 11.5 MockChunker

```dart
final class MockChunker implements IChunker {
  final String id = 'mock-chunker-v1';
  final String version = '1';
  final int maxChunkSize;  // default: 200

  // Разбивает по maxChunkSize символов, без overlap
  // Достаточно для проверки механики pipeline
}
```

### 11.6 PlainTextExtractor

```dart
final class PlainTextExtractor implements IContentExtractor {
  final String id = 'plain-text-v1';
  final String version = '1';
  final Set<String> supportedContentTypes = {'text/plain', 'text/markdown'};

  // Декодирует байты как UTF-8, возвращает ExtractedContent
}
```

---

## 12. Мультитенантность

Тенантность реализована на двух уровнях:

**Уровень 1 — коллекция:** имя коллекции содержит tenantId-префикс (существующий паттерн `{tenantId}__collection`). Используется в KnowledgeVault.

**Уровень 2 — payload фильтр:** `tenantId` в payload каждого VectorPoint + обязательный фильтр в `search()`. Используется в VectorRepository.

**Решение:** Оба уровня одновременно.  
**Обоснование:** Уровень 1 даёт физическую изоляцию (разные коллекции/таблицы). Уровень 2 — дополнительная защита от ошибок программиста. Defense in depth.

---

## 13. Hybrid Search (заложено, не реализовано)

Интерфейс `VectorStorage.search()` принимает `VaultQuery? filter` — это позволит в будущем добавить sparse vector (BM25) поиск без изменения интерфейса. Реализация — отдельный этап после базового dense search.

---

## 14. Схема зависимостей пакетов

```
aq_schema (интерфейсы и модели):
  ├── IContentExtractor
  ├── IModalityTransformer
  ├── IChunker
  ├── IEmbeddingsClient
  ├── IReranker
  ├── VectorStorage (существующий, расширить)
  ├── IVectorStoreRegistry
  ├── IndexingPipeline
  ├── VectorPoint, VectorPointPayload, PipelineStamp
  ├── ChunkSpan, ExtractedContent, ContentChunk
  ├── VectorSearchResult (существующий)
  ├── IndexingPipelineRecord (DirectStorable)
  ├── VectorStoreRecord (DirectStorable)
  └── IndexingStatus (добавить в StoredArtifact)

aq_data_layer (реализации):
  ├── InMemoryVectorStorage (существующий, доработать)
  ├── VectorStoreRegistryImpl
  ├── VectorRepositoryImpl (существующий, переработать)
  ├── PlainTextExtractor
  ├── MockChunker
  ├── MockEmbeddingsClient
  └── PassthroughReranker
```

---

## 15. Что намеренно отложено

| Компонент | Причина | Когда |
|---|---|---|
| PgVectorStorage | Требует pgvector extension в Docker | После InMemory работает |
| QdrantVectorStorage | Отдельный сервис | После pgvector |
| OpenAiEmbeddingsClient | Требует API key | После mock pipeline |
| SentenceChunker | NLP зависимость | После FixedSize работает |
| PdfExtractor | Требует PDF библиотеку | После text pipeline |
| Hybrid search (BM25) | +40% сложности | Отдельный этап |
| Streaming индексация | Требует очередь | Отдельный этап |
| Auto-reindex on file change | Требует event bus | Отдельный этап |

Все эти компоненты добавляются **без изменения существующих интерфейсов**.
