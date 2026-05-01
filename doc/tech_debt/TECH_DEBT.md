# Технический долг

**Дата:** 2026-05-01  
**Статус:** зафиксировано, не блокирует текущую работу

---

## Критический (блокирует фичи)

Нет.

---

## Высокий (нужно сделать до production)

### TD-001 — OllamaEmbeddingsClient / OpenAiEmbeddingsClient не реализованы

**Что:** Сейчас только `MockEmbeddingsClient` — детерминированные псевдо-векторы из hashCode. Реальный семантический поиск не работает.

**Где:** `aq_data_layer/lib/vector/`

**Что нужно:**
- `OllamaEmbeddingsClient` — HTTP к `http://{host}:11434/api/embeddings`
- `OpenAiEmbeddingsClient` — OpenAI API, модель `text-embedding-ada-002` или `text-embedding-3-small`

**Зависимость:** Ollama должна слушать на `0.0.0.0`, не `127.0.0.1`.  
Запуск: `OLLAMA_HOST=0.0.0.0 ollama serve`

**Влияние:** Без реальных эмбеддингов поиск работает, но результаты бессмысленны.

---

### TD-002 — PdfExtractor не реализован

**Что:** `PlainTextExtractor` поддерживает только `text/*`. PDF, DOCX, изображения — не поддерживаются.

**Где:** `aq_data_layer/lib/vector/`

**Что нужно:**
- `PdfExtractor implements IContentExtractor` — извлечение текста из PDF
- Dart библиотека: `pdf` (pub.dev) или вызов внешнего инструмента (`pdftotext`)
- `ImageExtractor` — для изображений через Ollama vision или OpenAI vision

**Влияние:** Нельзя индексировать PDF файлы.

---

### TD-003 — SentenceChunker не реализован

**Что:** `MockChunker` режет по фиксированному размеру символов — плохое качество чанков. Предложения разрезаются посередине.

**Где:** `aq_data_layer/lib/vector/`

**Что нужно:**
- `SentenceChunker implements IChunker` — разбивка по предложениям с overlap
- Алгоритм: split by `.!?`, затем группировать до maxTokens, overlap = последнее предложение

**Влияние:** Качество поиска хуже из-за обрезанных предложений.

---

### TD-004 — QdrantVectorStorage не реализован

**Что:** Только `InMemoryVectorStorage` (dev) и `PgVectorStorage` (production). Qdrant — более производительный вариант для больших корпусов (> 1M векторов).

**Где:** `aq_data_layer/lib/storage/`

**Что нужно:**
- `QdrantVectorStorage implements VectorStorage`
- HTTP API: `POST /collections/{name}/points/upsert`, `POST /collections/{name}/points/search`
- Фильтрация по payload: `{"must": [{"key": "tenantId", "match": {"value": "..."}}]}`

**Влияние:** При > 500k векторов pgvector начинает тормозить.

---

## Средний (нужно до стабильного релиза)

### TD-005 — flutter_client widget test сломан

**Что:** `example/stack/flutter_client` — smoke test не соответствует текущему UI.

**Где:** `example/stack/flutter_client/test/`

**Что нужно:** Обновить тест под текущий UI или удалить если flutter_client не поддерживается.

---

### TD-006 — postgres_example.dart вне Docker стека

**Что:** `example/postgres_example.dart` требует локальный PostgreSQL, не запускается в Docker стеке.

**Где:** `example/postgres_example.dart`

**Что нужно:** Либо добавить в docker-compose как отдельный сервис, либо удалить.

---

### TD-007 — VectorRepository не экспортирован как единый фасад

**Что:** Клиент должен создавать `VectorRepositoryImpl` вручную, передавая `IVectorStoreRegistry`. Нет удобного фасада типа `Vault.vectors(...)`.

**Где:** `aq_data_layer/lib/dart_vault.dart`, `lib/client/vault.dart`

**Что нужно:**
```dart
// Желаемый API:
final vectorRepo = await Vault.vectorRepository(
  storeId: 'pgvector-main',
  embedder: OllamaEmbeddingsClient(model: 'nomic-embed-text'),
);
final results = await vectorRepo.search('query', tenantId: tenantId);
```

---

### TD-008 — Нет батч-ограничений в embedBatch

**Что:** `IEmbeddingsClient.embedBatch()` не ограничивает размер батча. OpenAI API: max 2048 inputs. При большом документе — ошибка.

**Где:** `aq_data_layer/lib/vector/`

**Что нужно:** В `VectorRepositoryImpl.index()` разбивать chunks на батчи по N (конфигурируемо).

---

### TD-009 — IndexingStatus не обновляется при reindex

**Что:** `VectorRepositoryImpl.reindex()` вызывает `deleteDocument` + `index`. Между ними статус артефакта = `none` (после delete). Если сервер упадёт — статус останется `none`.

**Где:** `aq_data_layer/lib/storage/vector_repository_impl.dart`

**Что нужно:** Установить `stale` перед reindex, не `none`.

---

### TD-010 — RemoteVectorStorage не поддерживает getById/getAll

**Что:** `RemoteVectorStorage.getById()` и `getAll()` возвращают `null`/`[]` — не реализованы.

**Где:** `aq_data_layer/lib/client/remote/remote_vector_storage.dart`

**Что нужно:** Добавить RPC операции `vectorGet` и `vectorGetAll` в `VaultRegistry.dispatch()`.

---

## Низкий (nice to have)

### TD-011 — Hybrid search (BM25 + dense) не реализован

**Что:** Только dense vector search. Keyword search (точные совпадения имён, кодов) работает плохо.

**Решение:** `ISparseEncoder` интерфейс + `tsvector` в PostgreSQL для BM25. Интерфейс уже заложен в архитектуре.

---

### TD-012 — Reranker не реализован (только PassthroughReranker)

**Что:** После similarity search результаты не переранжируются. Cohere Rerank или BGE-reranker значительно улучшают качество RAG.

**Решение:** `CohereReranker implements IReranker` или локальный cross-encoder через Ollama.

---

### TD-013 — Нет streaming индексации

**Что:** `index()` — синхронный вызов. Большой документ (100 страниц PDF) блокирует на секунды.

**Решение:** Очередь задач (существующий `JobQueue` в aq_schema) + async worker.

---

### TD-014 — VectorStoreRecord не синхронизируется с реальным состоянием

**Что:** `VectorStoreRecord` в БД — статичная запись. Если store недоступен — запись всё равно `isActive: true`.

**Решение:** Health check при старте сервера + обновление `isActive`.

---

## Сводная таблица

| ID | Приоритет | Описание | Блокирует |
|---|---|---|---|
| TD-001 | 🔴 Высокий | OllamaEmbeddingsClient | Реальный поиск |
| TD-002 | 🔴 Высокий | PdfExtractor | PDF индексация |
| TD-003 | 🔴 Высокий | SentenceChunker | Качество поиска |
| TD-004 | 🔴 Высокий | QdrantVectorStorage | Масштаб > 500k |
| TD-005 | 🟡 Средний | flutter_client test | — |
| TD-006 | 🟡 Средний | postgres_example.dart | — |
| TD-007 | 🟡 Средний | Vault.vectorRepository() фасад | UX |
| TD-008 | 🟡 Средний | embedBatch лимиты | Стабильность |
| TD-009 | 🟡 Средний | IndexingStatus при reindex | Корректность |
| TD-010 | 🟡 Средний | RemoteVectorStorage getById/getAll | Полнота API |
| TD-011 | 🟢 Низкий | Hybrid search | Качество поиска |
| TD-012 | 🟢 Низкий | Reranker | Качество RAG |
| TD-013 | 🟢 Низкий | Streaming индексация | Производительность |
| TD-014 | 🟢 Низкий | VectorStore health check | Надёжность |
