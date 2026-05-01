# Vector Search — Сценарии использования

**Дата:** 2026-05-01  
**Принцип:** aq_data_layer = хранение + поиск + ранжирование. LLM — снаружи.

---

## Граница ответственности

```
┌─────────────────────────────────────────────────────────┐
│  Внешний код (LLM, приложение)                          │
│  - Генерация ответов                                    │
│  - Выбор что делать с чанками                           │
│  - Бизнес-логика                                        │
└──────────────────┬──────────────────────────────────────┘
                   │ query vector + filters
┌──────────────────▼──────────────────────────────────────┐
│  aq_data_layer (этот пакет)                             │
│  - Хранение векторов                                    │
│  - Dense similarity search (cosine/dot/euclidean)       │
│  - Sparse search (BM25/TF-IDF) — hybrid                 │
│  - Фильтрация по payload                                │
│  - Ранжирование (reranker)                              │
│  - Возврат: List<VectorSearchResult> с scores           │
└─────────────────────────────────────────────────────────┘
```

---

## Группа 1 — Базовый поиск

### S-01: Dense similarity search
**Файл:** `main_search_dense.dart`

Проверяет основную механику cosine similarity.

```
Setup: 10 чанков из 3 документов разной тематики (AI, DB, Security)
       Embedder: Ollama nomic-embed-text

1. Exact match: запрос = точная фраза из документа → score > 0.9
2. Semantic match: запрос = синоним → score > 0.7
3. Unrelated: запрос из другой темы → score < 0.3
4. topK=1: возвращает ровно 1 результат
5. topK=5: возвращает ≤ 5 результатов
6. scoreThreshold=0.5: отсекает нерелевантные
7. Порядок: результаты отсортированы по score DESC
```

**Критерий успеха:** Exact match score > 0.9, semantic > 0.7, порядок правильный.

---

### S-02: Metric variants
**Файл:** `main_search_metrics.dart`

Проверяет разные метрики расстояния.

```
Setup: нормализованные векторы (unit vectors)

1. Cosine: 1 - cos(angle) — стандарт для текста
2. Dot product: для нормализованных = cosine, быстрее
3. Euclidean: L2 distance — для временных рядов
4. Verify: для нормализованных векторов cosine ≈ dot product
5. Verify: разные метрики дают разный порядок на ненормализованных
```

---

### S-03: Filter search
**Файл:** `main_search_filter.dart`

Фильтрация по payload полям.

```
Setup: 20 чанков, 4 артефакта, 2 владельца, 1 тенант

1. Filter by artifactId: только чанки одного документа
2. Filter by ownerId: только документы одного пользователя
3. Filter by modality: только text чанки
4. Combined filter: artifactId + ownerId
5. Filter + topK: фильтр применяется ДО topK
6. Empty result: фильтр не совпадает → []
7. Verify: ни один результат не нарушает фильтр
```

---

### S-04: Multi-tenant isolation
**Файл:** `main_search_tenant.dart`

Тенантность — обязательный параметр, не опциональный.

```
Setup: 3 тенанта, по 5 документов каждый

1. Tenant A search → только документы A
2. Tenant B search → только документы B
3. Tenant C search → только документы C
4. Verify: ни один результат не содержит чужой tenantId
5. Cross-query: запрос из темы тенанта B, выполнен от тенанта A → 0 результатов
6. Verify: tenantId обязателен — без него compile error (не runtime)
```

---

## Группа 2 — Качество поиска

### S-05: Precision@K evaluation
**Файл:** `main_search_precision.dart`

Объективная оценка качества — единственный способ сравнивать embedder'ы.

```
Setup: 10 документов по разным темам
       5 запросов с известными правильными ответами (ground truth)

Для каждого запроса:
  - Search топ-3
  - Проверить что правильный документ в топ-3
  - Записать hit/miss

Метрики:
  - Precision@1: правильный документ на 1-м месте
  - Precision@3: правильный документ в топ-3
  - MRR (Mean Reciprocal Rank): 1/rank правильного документа

Критерий: Precision@3 ≥ 0.8 (4 из 5 запросов правильные)
```

**Почему важно:** Без этого нельзя объективно сравнить MockEmbedder vs Ollama vs OpenAI.

---

### S-06: Chunking quality impact
**Файл:** `main_search_chunking.dart`

Влияние стратегии чанкования на качество поиска.

```
Один документ, три стратегии:
  A. MockChunker(maxChunkSize=200) — фиксированный размер
  B. MockChunker(maxChunkSize=500) — большие чанки
  C. SentenceChunker — по предложениям с overlap (когда реализован)

Для каждой стратегии:
  - Проиндексировать
  - Выполнить 3 запроса
  - Записать scores

Вывод: таблица сравнения scores по стратегиям
```

---

### S-07: Score normalization
**Файл:** `main_search_scores.dart`

Проверяет что scores в диапазоне [0, 1] и имеют смысл.

```
1. Identical vectors: score = 1.0
2. Opposite vectors: score = 0.0 (после clamp)
3. Orthogonal vectors: score ≈ 0.5
4. All scores in [0, 1]
5. Score ordering: более похожий текст → выше score
6. Verify: "machine learning" vs "deep learning" > "machine learning" vs "SQL injection"
```

---

## Группа 3 — Hybrid Search

### S-08: Hybrid search (dense + sparse)
**Файл:** `main_search_hybrid.dart`

Комбинирует semantic search с keyword search.

```
Проблема: dense search плохо находит точные совпадения (имена, коды, термины)
Решение: BM25 для точных совпадений + cosine для семантики

Setup: документы содержат специфические термины (UUID, имена функций, коды ошибок)

1. Dense only: поиск "ERR_CONNECTION_REFUSED" → плохой результат
2. Sparse only (BM25): поиск "ERR_CONNECTION_REFUSED" → точное совпадение
3. Hybrid (alpha=0.5): лучший из обоих
4. Alpha tuning:
   - alpha=0.0: только BM25 (keyword)
   - alpha=1.0: только dense (semantic)
   - alpha=0.5: баланс
5. Verify: hybrid ≥ max(dense, sparse) для большинства запросов
```

**Статус:** Требует реализации `ISparseEncoder` + BM25 в pgvector (tsvector).

---

### S-09: Reranker
**Файл:** `main_search_reranker.dart`

Переранжирование результатов после первичного поиска.

```
1. Search топ-10 (широкий поиск)
2. Rerank топ-10 → топ-3 (точный)
3. Verify: после rerank порядок изменился
4. Verify: precision@3 после rerank > precision@3 без rerank
5. PassthroughReranker: порядок не меняется (baseline)
```

**Статус:** Интерфейс есть, нужна реальная реализация (cross-encoder или Cohere).

---

## Группа 4 — Lifecycle

### S-10: Index → Reindex → Delete
**Файл:** `main_search_lifecycle.dart`

Полный жизненный цикл документа.

```
1. Index v1 → search → найден
2. Verify: IndexingStatus = indexed, chunkCount = N
3. Reindex v2 (другой контент) → search v1 контент → не найден
4. Verify: chunkCount обновлён, stamp обновлён
5. Delete → search → 0 результатов
6. Verify: IndexingStatus = none (или deleted)
7. Re-index после delete → работает
```

---

### S-11: Concurrent indexing
**Файл:** `main_search_concurrent.dart`

Параллельная индексация без конфликтов.

```
1. 10 документов, индексировать параллельно (Future.wait)
2. Verify: все 10 status = indexed
3. Verify: нет дублирующихся chunk id
4. Verify: search работает по всем 10
5. Измерить: parallel time vs sequential time
6. Verify: parallel ≤ sequential * 1.5 (не деградирует)
```

---

### S-12: Embedder migration
**Файл:** `main_search_migration.dart`

Смена embedder без потери данных.

```
1. Index с MockEmbeddingsClient (dim=8, storeId=mock-store)
2. Search с mock → результаты есть
3. Reindex с OllamaEmbeddingsClient (dim=768, storeId=pgvector-main)
4. Search с Ollama → результаты есть, scores выше
5. Search с mock в mock-store → 0 (старые чанки удалены из mock-store)
6. Verify: PipelineStamp.embedderId = 'ollama-nomic-embed-text'
7. Verify: два store сосуществуют без конфликтов
```

---

## Группа 5 — Интеграционные (LLM снаружи)

> Эти сценарии показывают как внешний код использует пакет.
> aq_data_layer только отдаёт чанки — что с ними делать решает вызывающий код.

### S-13: RAG context assembly
**Файл:** `main_integration_rag.dart`

```
1. Index 5 документов
2. Query: "SQL injection prevention"
3. Search → топ-3 чанка с scores
4. Собрать контекст: join chunk texts
5. Verify: контекст содержит релевантный текст
6. Verify: контекст не превышает max_tokens (4096)
7. Print: готовый контекст для передачи в LLM

// LLM вызов — НЕ в этом пакете:
// final answer = await llm.complete(context + question);
```

---

### S-14: Annotation-driven search
**Файл:** `main_integration_annotations.dart`

```
1. Index документ
2. Search → найти чанк
3. Создать LLM аннотацию (vectorRef) с chunkId
4. Найти все аннотации типа vectorRef для документа
5. По chunkId найти оригинальный чанк
6. Verify: chunkId в аннотации → реальный чанк существует
7. Verify: span в чанке → правильная позиция в документе
```

---

## Группа 6 — Производительность

### S-15: Search latency
**Файл:** `main_perf_latency.dart`

```
Setup: 1000 чанков (10 документов × 100 чанков)

1. Single search: измерить p50, p95, p99 latency (100 запросов)
2. Batch search: 10 параллельных запросов
3. Verify: p95 < 100ms для InMemory
4. Verify: p95 < 500ms для pgvector (без GPU)
5. Вывод: таблица latency по backend
```

---

## Порядок реализации

```
Фаза 1 — Точность поиска (сейчас):
  S-01 Dense search          ← базовая механика
  S-03 Filter search         ← фильтрация
  S-04 Multi-tenant          ← безопасность
  S-05 Precision@K           ← объективная оценка качества
  S-07 Score normalization   ← корректность

Фаза 2 — Качество (после SentenceChunker):
  S-06 Chunking quality
  S-10 Lifecycle
  S-11 Concurrent

Фаза 3 — Hybrid search (новая реализация):
  S-08 Hybrid search
  S-09 Reranker

Фаза 4 — Интеграционные:
  S-12 Migration
  S-13 RAG context
  S-14 Annotations

Фаза 5 — Производительность:
  S-15 Latency
```
