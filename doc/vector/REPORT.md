# Vector Layer — Implementation Report

**Дата:** 2026-05-01  
**Статус:** ✅ Все сценарии пройдены

---

## Результаты прогона

### stack-artifacts — 6/6 ✅
```
✅ Bytes uploaded: 308 bytes
✅ Metadata saved: artifact-doc-001 (308 bytes)
✅ Found by id: test-document.md (308 bytes)
✅ Found by contentType: 1 artifact(s)
✅ User annotation saved: annotation-user-001 [highlight]
✅ LLM annotation saved: annotation-llm-001 [vector_ref] actor=gpt-4o
✅ History entries: 6
✅ Downloaded: 308 bytes, content verified
Results: 6 passed, 0 failed
```

### stack-vector — 9/9 ✅
```
✅ Indexed: 2 chunks in 2ms
✅ Search results: 2 (score=0.2551, score=0.0000)
✅ Filter by artifactId: 2 results, all from art-vec-001
✅ Reindexed: 1 chunks
✅ Deleted: 0 results after deletion
✅ Multi-tenant isolation: tenant A sees 1 results, none from tenant B
✅ Pipeline record: mock-pipeline-v1 embedder=mock-v1 dim=8
✅ Artifact status: indexed chunks=1
✅ Failed status: failed error="Unsupported operation: Content type not supported"
Results: 9 passed, 0 failed
```

### stack-knowledge — 7/7 ✅
```
✅ Uploaded + indexed: 5 chunks
✅ Search: 3 results, top chunk: know-doc-001__chunk-3
✅ User annotation: know-annot-user-001 [highlight]
✅ LLM annotation: know-annot-llm-001 chunkId=know-doc-001__chunk-3
✅ Annotation → chunk link verified: know-doc-001__chunk-3
✅ Reindexed: 5 chunks
✅ Deleted: 0 chunks remain
Results: 7 passed, 0 failed
```

---

## Что реализовано

### Stage 0 — Модели и интерфейсы (aq_schema)

| Файл | Описание |
|---|---|
| `data_layer/vector/chunk_span.dart` | Позиция чанка в оригинале (text/audio/video/pdf) |
| `data_layer/vector/pipeline_stamp.dart` | Data lineage — полная история создания чанка |
| `data_layer/vector/extracted_content.dart` | Промежуточная модель после извлечения (in-memory) |
| `data_layer/vector/content_chunk.dart` | Чанк после разбивки (in-memory) |
| `data_layer/vector/vector_point_payload.dart` | Типизированный payload VectorEntry |
| `data_layer/vector/indexing_result.dart` | Результат индексации |
| `data_layer/pipeline/i_content_extractor.dart` | Интерфейс извлечения контента |
| `data_layer/pipeline/i_modality_transformer.dart` | Интерфейс трансформации модальности |
| `data_layer/pipeline/i_chunker.dart` | Интерфейс разбивки на чанки |
| `data_layer/pipeline/i_embeddings_client.dart` | Интерфейс эмбеддингов |
| `data_layer/pipeline/i_reranker.dart` | Интерфейс реранкера |
| `data_layer/pipeline/i_vector_store_registry.dart` | Реестр хранилищ + VectorStoreDescriptor |
| `data_layer/pipeline/indexing_pipeline.dart` | Конфигурация pipeline |
| `data_layer/storable/indexing_pipeline_record.dart` | DirectStorable — справочник pipeline |
| `data_layer/storable/vector_store_record.dart` | DirectStorable — справочник store |
| `data_layer/storable/stored_artifact.dart` | +IndexingStatus, +copyWith() |
| `data_layer/storage/vector_storage.dart` | +tenantId required, +metric в search() |

### Stage 1 — Реализации (aq_data_layer)

| Файл | Описание |
|---|---|
| `lib/vector/mock_embeddings_client.dart` | Детерминированные эмбеддинги из hashCode |
| `lib/vector/mock_chunker.dart` | Fixed-size chunker для тестов |
| `lib/vector/plain_text_extractor.dart` | Extractor для text/plain, text/markdown |
| `lib/vector/passthrough_reranker.dart` | No-op reranker |
| `lib/vector/vector_store_registry_impl.dart` | Реестр хранилищ |
| `lib/storage/vector_repository_impl.dart` | Полный pipeline оркестратор |
| `lib/storage/simple_vector_repository_impl.dart` | Простая обёртка для KnowledgeVault |
| `lib/storage/in_memory_vector_storage.dart` | +tenantId фильтрация в search() |

### Stage 2 — Справочники в БД

- `IndexingPipelineRecord` и `VectorStoreRecord` добавлены в `AqDomains.all`
- `VectorRepositoryImpl.index()` сохраняет `IndexingPipelineRecord` при первом использовании
- `VectorRepositoryImpl.index()` обновляет `StoredArtifact.indexingStatus`:
  - `indexing` → в процессе
  - `indexed` → успех (+ chunkCount, indexedStoreId, indexedAt)
  - `failed` → ошибка (+ indexingError)

### Stage 3 — Сценарии

| Файл | Сценарии |
|---|---|
| `main_vector.dart` | 9 сценариев: index, search, filter, reindex, delete, multi-tenant, pipeline record, artifact status, failed status |
| `main_knowledge.dart` | 7 сценариев: upload+index, search, user annotation, LLM annotation, verify link, reindex, delete |
| `Dockerfile.vector` | Образ для vector сценариев |
| `Dockerfile.knowledge` | Образ для knowledge сценариев |
| `docker-compose.yml` | +vector, +knowledge сервисы |

---

## Архитектурные решения подтверждены

| Решение | Результат |
|---|---|
| `tenantId` обязательный в `search()` | ✅ Компилятор не даёт забыть |
| `PipelineStamp` в каждом чанке | ✅ Фильтрация по embedderId работает |
| `storeId` в payload | ✅ Чанк знает своё хранилище |
| `IndexingStatus` в `StoredArtifact` | ✅ Статус обновляется автоматически |
| Mock pipeline достаточен для механики | ✅ Все сценарии проходят без реальных эмбеддингов |
| Один сервер для всех сценариев | ✅ postgres + server, все клиенты завершаются |

---

## Следующие шаги (по плану)

- **Stage 4:** ✅ PgVectorStorage — pgvector/pgvector:pg15, реальная БД
- **Stage 5:** ✅ Remote RPC transport — RemoteVectorStorage клиент
- **Future:** OpenAiEmbeddingsClient, PdfExtractor, SentenceChunker, QdrantVectorStorage
