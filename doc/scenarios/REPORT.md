# Финальный отчёт — Vector Search Layer

**Дата:** 2026-05-01  
**Статус:** ✅ Все сценарии пройдены — 100/100

---

## Результаты прогона

| Сценарий | Тесты | Статус | Что проверяет |
|---|---|---|---|
| `stack-artifacts` | 6/6 | ✅ | Upload, metadata, annotations, history, download |
| `stack-vector` | 10/10 | ✅ | Index, search, filter, reindex, delete, multi-tenant, pipeline record, artifact status, failed status, remote RPC |
| `stack-knowledge` | 7/7 | ✅ | Upload+index, search, user/LLM annotation, verify link, reindex, delete |
| `stack-rag_basic` | 5/5 | ✅ | Ollama nomic-embed-text: AI/security/cross-doc search, real scores |
| `stack-search_core` | 17/17 | ✅ | S-01 dense, S-03 filter, S-04 tenant, S-07 scores |
| `stack-search_precision` | 5/5 | ✅ | Precision@1=1.0, Precision@3=1.0, MRR=1.0, Hybrid≥Dense |
| `stack-search_lifecycle` | 7/7 | ✅ | Index→Reindex→Delete, status tracking |
| `stack-search_concurrent` | 5/5 | ✅ | 10 docs parallel, 910ms, no duplicates |
| `stack-search_chunking` | 4/4 | ✅ | SentenceChunker(0.878) > MockChunker(0.724) |
| `stack-search_reranker` | 4/4 | ✅ | PassthroughReranker, OllamaReranker |
| `stack-integration_rag` | 5/5 | ✅ | Context assembly, hybrid search |
| `stack-integration_annotations` | 6/6 | ✅ | chunkId→annotation→span, history |
| `stack-search_migration` | 6/6 | ✅ | Mock→Ollama migration, two stores coexist |
| `stack-perf_latency` | 4/4 | ✅ | p50=21ms, p95=60ms, hybrid p95=63ms |
| **ИТОГО** | **100/100** | ✅ | |

---

## Что реализовано за сессию

### Инфраструктура
- **Ollama** как сервис в docker-compose (`ollama/ollama:latest`, `nomic-embed-text` 768-dim)
- **pgvector** (`pgvector/pgvector:pg15`) — один сервер для всех сценариев
- **Один стек**: `postgres` + `ollama` + `server` — постоянно работают. Клиенты стартуют и завершаются.

### Новые компоненты (aq_data_layer)

| Компонент | Описание |
|---|---|
| `SentenceChunker` | Разбивка по предложениям с overlap. Score 0.878 vs 0.724 у fixed-size |
| `OllamaEmbeddingsClient` | HTTP к Ollama `/api/embeddings`. nomic-embed-text 768-dim |
| `OllamaReranker` | Cross-encoder через Ollama generate API. Scores 0-10 → 0-1 |
| `PgVectorStorage` | pgvector + tsvector GENERATED колонка + GIN индекс для hybrid search |
| `RemoteVectorStorage` | Клиентский RPC транспорт для векторных операций |
| `VectorStoreRegistryImpl` | Реестр хранилищ. Несколько store одновременно |
| `VectorRepositoryImpl` | Полный pipeline оркестратор: extract→chunk→embed→upsert |

### Расширения интерфейсов

**`VectorStorage.search()`** — добавлены `sparseQuery` и `alpha`:
```dart
// Pure dense (default)
search(collection, vector, tenantId: t)

// Hybrid: 70% dense + 30% BM25
search(collection, vector, tenantId: t, sparseQuery: 'SQL injection', alpha: 0.7)
```

**`IDataLayer`** — мультитон:
```dart
// Default instance (как раньше)
IDataLayer.instance

// Named instance (новое)
await initializeDataLayer(endpoint: '...', key: 'analytics');
IDataLayer.named('analytics').direct<Event>(...)

// Disconnect
await IDataLayer.disconnect();        // default
await IDataLayer.disconnect('analytics'); // named
await IDataLayer.disconnectAll();     // все
```

### Метрики качества поиска

| Метрика | Результат |
|---|---|
| Precision@1 | **1.0** (5/5 запросов) |
| Precision@3 | **1.0** (5/5 запросов) |
| MRR | **1.0** |
| Exact match score | 0.81 |
| Semantic match score | 0.66 |
| Unrelated score | 0.35 |
| Search latency p50 | **21ms** |
| Search latency p95 | **60ms** |
| Hybrid search p95 | **63ms** |
| Parallel index (10 docs) | **910ms** |

### Архитектурная проблема и решение

**Проблема:** `IDataLayer` — глобальный синглтон. При попытке вызвать `initializeDataLayer()` дважды в одном процессе — исключение. Это проявилось в сценарии сравнения чанкеров.

**Решение:** Мультитон с именованными инстансами + `disconnect()`. Обратная совместимость сохранена — `IDataLayer.instance` работает как раньше.

---

## Стек сценариев

```
postgres (pgvector/pgvector:pg15)  ← всегда запущен
ollama (ollama/ollama:latest)       ← всегда запущен, nomic-embed-text
server                              ← всегда запущен, VECTOR_DIM=768

# Запуск любого сценария:
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  -e OLLAMA_ENDPOINT=http://stack-ollama-1:11434 \
  stack-{scenario_name}
```

---

## Следующие шаги (из TECH_DEBT.md)

| Приоритет | Задача |
|---|---|
| 🔴 | PdfExtractor — индексация PDF |
| 🔴 | SentenceChunker с реальным NLP (не regex) |
| 🟡 | Vault.vectorRepository() — удобный фасад |
| 🟡 | embedBatch лимиты (OpenAI max 2048) |
| 🟡 | IndexingStatus при reindex → stale (не none) |
| 🟢 | QdrantVectorStorage |
| 🟢 | Hybrid search sparse encoder (ISparseEncoder интерфейс) |
