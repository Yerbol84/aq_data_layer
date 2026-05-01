# Vector Search Scenarios — План реализации

**Дата:** 2026-05-01

---

## Фаза 1 — Точность поиска (приоритет сейчас)

Цель: объективно измерить и улучшить качество поиска.

### Шаг 1.1 — SentenceChunker

**Почему первым:** MockChunker режет по символам — предложения разрезаются посередине.
Это главная причина низкого качества чанков.

```dart
// Алгоритм:
// 1. Split по .!? с учётом аббревиатур
// 2. Группировать предложения до maxTokens (~200 слов)
// 3. Overlap = последнее предложение предыдущего чанка
final class SentenceChunker implements IChunker {
  final int maxChunkTokens;  // ~200
  final bool overlap;        // включить overlap
}
```

Файл: `aq_data_layer/lib/vector/sentence_chunker.dart`

---

### Шаг 1.2 — Сценарии S-01, S-03, S-04, S-07

Четыре сценария в одном файле `main_search_core.dart`:

**S-01 Dense search** — проверяет exact match (>0.9), semantic (>0.7), unrelated (<0.3), порядок.

**S-03 Filter search** — фильтрация по artifactId, ownerId, combined.

**S-04 Multi-tenant** — изоляция, cross-query возвращает 0.

**S-07 Score normalization** — identical=1.0, scores в [0,1], ordering корректный.

---

### Шаг 1.3 — Сценарий S-05 Precision@K

Отдельный файл `main_search_precision.dart` — объективная оценка.

Ground truth (5 запросов × правильный документ):
```dart
const _groundTruth = {
  'how does vector similarity work': 'doc-ai',
  'SQL injection parameterized queries': 'doc-security',
  'PostgreSQL connection pooling': 'doc-db',
  'JWT token expiration validation': 'doc-security',
  'transformer attention mechanism': 'doc-ai',
};
```

Метрики: Precision@1, Precision@3, MRR.

---

### Шаг 1.4 — Hybrid Search (S-08)

**Архитектура:**

```
VectorStorage.search() получает новый параметр:
  sparseQuery: String?  // если задан — hybrid mode

Реализация в PgVectorStorage:
  1. Dense: vector <=> query_vector (cosine)
  2. Sparse: ts_rank(to_tsvector(payload->>'text'), plainto_tsquery(sparseQuery))
  3. Combine: score = alpha * dense_score + (1-alpha) * sparse_score
  4. alpha: параметр в search() [0.0=only sparse, 1.0=only dense, 0.5=balanced]
```

Изменения в интерфейсе:
```dart
// VectorStorage.search() добавить:
String? sparseQuery,   // текст для BM25
double alpha = 1.0,    // 1.0 = только dense, 0.0 = только sparse
```

PostgreSQL:
```sql
-- Добавить tsvector колонку в таблицу
ALTER TABLE {collection} ADD COLUMN IF NOT EXISTS text_search tsvector
  GENERATED ALWAYS AS (to_tsvector('english', payload->>'text')) STORED;

CREATE INDEX IF NOT EXISTS {collection}_text_idx
  ON {collection} USING gin(text_search);
```

---

## Фаза 2 — Lifecycle и качество чанков

### Шаг 2.1 — S-06 Chunking quality comparison

`main_search_chunking.dart` — сравнение MockChunker vs SentenceChunker.
Показывает разницу в scores.

### Шаг 2.2 — S-10 Lifecycle

`main_search_lifecycle.dart` — index → reindex → delete, проверка статусов.

### Шаг 2.3 — S-11 Concurrent indexing

`main_search_concurrent.dart` — Future.wait на 10 документов, проверка отсутствия конфликтов.

---

## Фаза 3 — Reranker

### Шаг 3.1 — CrossEncoderReranker (через Ollama)

```dart
// Использует Ollama для оценки релевантности query-document пары
final class OllamaReranker implements IReranker {
  // Для каждого кандидата: prompt = "Rate relevance 0-10: query={q} document={d}"
  // Парсить число из ответа → новый score
  // Пересортировать по новому score
}
```

### Шаг 3.2 — S-09 Reranker scenario

`main_search_reranker.dart` — сравнение precision@3 до и после rerank.

---

## Фаза 4 — Интеграционные

### Шаг 4.1 — S-12 Migration

`main_search_migration.dart` — смена embedder, два store сосуществуют.

### Шаг 4.2 — S-13, S-14

`main_integration_rag.dart` — context assembly без LLM вызова.
`main_integration_annotations.dart` — chunkId → аннотация → позиция в документе.

---

## Фаза 5 — Производительность

### Шаг 5.1 — S-15 Latency benchmark

`main_perf_latency.dart` — 1000 чанков, p50/p95/p99 latency.

---

## Сводная таблица

| Шаг | Файл | Зависимость | Приоритет |
|---|---|---|---|
| 1.1 | `sentence_chunker.dart` | — | 🔴 |
| 1.2 | `main_search_core.dart` | Ollama | 🔴 |
| 1.3 | `main_search_precision.dart` | Ollama | 🔴 |
| 1.4 | Hybrid search в VectorStorage | pgvector tsvector | 🔴 |
| 2.1 | `main_search_chunking.dart` | SentenceChunker | 🟡 |
| 2.2 | `main_search_lifecycle.dart` | — | 🟡 |
| 2.3 | `main_search_concurrent.dart` | — | 🟡 |
| 3.1 | `OllamaReranker` | Ollama LLM | 🟡 |
| 3.2 | `main_search_reranker.dart` | OllamaReranker | 🟡 |
| 4.1 | `main_search_migration.dart` | — | 🟢 |
| 4.2 | `main_integration_*.dart` | — | 🟢 |
| 5.1 | `main_perf_latency.dart` | — | 🟢 |

---

## Начинаем с Шага 1.1 — SentenceChunker
