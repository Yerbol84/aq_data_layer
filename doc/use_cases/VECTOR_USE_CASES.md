# Сценарии использования векторной БД

**Дата:** 2026-05-01  
**Статус:** планирование реализации  
**Зависимость:** Ollama (`OLLAMA_HOST=0.0.0.0 ollama serve`) или OpenAI API key

---

## Ollama — подключение

Ollama на хост-машине доступна из контейнеров через gateway:

```
http://172.22.0.1:11434
```

**Требование:** Ollama должна слушать на всех интерфейсах:
```bash
# На хост-машине:
OLLAMA_HOST=0.0.0.0 ollama serve
```

**Проверка доступности:**
```bash
curl http://172.22.0.1:11434/api/tags
```

**Рекомендуемые модели для эмбеддингов:**

| Модель | Размер | Dim | Качество |
|---|---|---|---|
| `nomic-embed-text` | 274MB | 768 | ⭐⭐⭐⭐ рекомендуется |
| `mxbai-embed-large` | 670MB | 1024 | ⭐⭐⭐⭐⭐ лучшее качество |
| `all-minilm` | 46MB | 384 | ⭐⭐⭐ быстрый, лёгкий |

```bash
# Установить модель:
ollama pull nomic-embed-text
```

---

## Сценарий 1 — Базовый RAG (текстовые документы)

**Задача:** Загрузить markdown документы, проиндексировать, найти релевантные чанки по вопросу.

**Файл:** `main_rag_basic.dart`

```
1. Инициализация: OllamaEmbeddingsClient(model: 'nomic-embed-text', host: '172.22.0.1')
2. Upload 3 markdown файла разной тематики (AI, databases, security)
3. Index каждый файл через pipeline (PlainTextExtractor → SentenceChunker → Ollama)
4. Search: "how does vector similarity work?" → топ-3 чанка
5. Verify: результаты из AI документа, не из database/security
6. Search: "SQL injection prevention" → результаты из security документа
7. Cross-doc search: "data storage" → результаты из нескольких документов
8. Print: для каждого результата — score, artifactId, текст чанка
```

**Ожидаемый результат:** Семантически релевантные чанки, не просто keyword match.

---

## Сценарий 2 — Multi-tenant knowledge base

**Задача:** Два тенанта с разными документами. Поиск изолирован.

**Файл:** `main_rag_multitenant.dart`

```
1. Tenant A: загрузить документы о медицине
2. Tenant B: загрузить документы о финансах
3. Search tenant A: "treatment options" → только медицинские чанки
4. Search tenant B: "investment portfolio" → только финансовые чанки
5. Search tenant A с запросом из tenant B: "stock market" → 0 результатов
6. Verify: ни один результат не содержит данные другого тенанта
```

---

## Сценарий 3 — Аннотации + векторный поиск

**Задача:** Пользователь выделяет текст → LLM создаёт vectorRef аннотацию → поиск возвращает аннотированные места.

**Файл:** `main_rag_annotations.dart`

```
1. Upload документ (технический мануал)
2. Index документ
3. User highlight: страница 2, offset 450-520, "важный раздел"
4. Search: "важный раздел" → найти чанк
5. LLM annotation: vectorRef с chunkId из результата поиска
6. Verify: аннотация содержит правильный chunkId
7. Find annotation by chunkId: показать где в документе
8. History: показать историю изменений аннотации
```

---

## Сценарий 4 — Переиндексация при обновлении документа

**Задача:** Документ обновился → старые чанки удалены → новые проиндексированы → поиск возвращает новый контент.

**Файл:** `main_rag_reindex.dart`

```
1. Upload v1 документа (содержит "старый контент")
2. Index v1
3. Search: "старый контент" → найден
4. Search: "новый контент" → не найден
5. Upload v2 документа (содержит "новый контент", убран "старый контент")
6. Reindex (deleteDocument + index)
7. Search: "старый контент" → не найден (0 результатов)
8. Search: "новый контент" → найден
9. Verify: IndexingStatus = indexed, chunkCount обновлён
```

---

## Сценарий 5 — Поиск с фильтром по артефакту

**Задача:** Поиск только внутри конкретного документа (не по всей базе).

**Файл:** `main_rag_filtered.dart`

```
1. Upload 5 документов разной тематики
2. Index все 5
3. Search без фильтра: "data" → результаты из всех документов
4. Search с artifactId фильтром → только из одного документа
5. Verify: все результаты имеют правильный artifactId
6. Search с ownerId фильтром → только документы конкретного пользователя
```

---

## Сценарий 6 — Сравнение Mock vs Ollama эмбеддингов

**Задача:** Показать разницу в качестве поиска между mock и реальными эмбеддингами.

**Файл:** `main_rag_embedder_comparison.dart`

```
1. Upload один документ
2. Index с MockEmbeddingsClient (dim=8)
3. Search: "machine learning" → результаты (случайные, нет семантики)
4. Reindex с OllamaEmbeddingsClient(nomic-embed-text, dim=768)
5. Search: "machine learning" → результаты (семантически релевантные)
6. Search: "ML algorithms" → те же результаты (синонимы работают)
7. Print: сравнение scores mock vs ollama
```

---

## Сценарий 7 — Большой документ (chunking механика)

**Задача:** Проверить что большой документ правильно разбивается и все чанки индексируются.

**Файл:** `main_rag_large_doc.dart`

```
1. Сгенерировать документ 50KB (100 параграфов)
2. Index с MockChunker(maxChunkSize=200) → ~250 чанков
3. Verify: chunkCount = ожидаемое количество
4. Search: запрос из середины документа → найден правильный чанк
5. Verify: span.chunkIndex, span.startOffset, span.endOffset корректны
6. Delete → verify 0 чанков
```

---

## Сценарий 8 — Remote RPC pipeline (клиент → сервер)

**Задача:** Полный pipeline через RPC — клиент не знает о реализации хранилища.

**Файл:** `main_rag_remote.dart`

```
1. Клиент: initializeDataLayer(endpoint, authToken)
2. Клиент: создать RemoteVectorStorage
3. Клиент: создать VectorRepositoryImpl с RemoteVectorStorage
4. Upload файла через RemoteArtifactStorage
5. Index через RemoteVectorStorage (векторы хранятся в pgvector на сервере)
6. Search через RemoteVectorStorage
7. Verify: результаты идентичны прямому pgvector поиску
```

---

## Порядок реализации

```
Шаг 1: OllamaEmbeddingsClient (TD-001) — разблокирует сценарии 1,2,3,4,5,6
Шаг 2: SentenceChunker (TD-003) — улучшает качество всех сценариев
Шаг 3: main_rag_basic.dart — базовый RAG с Ollama
Шаг 4: main_rag_multitenant.dart — изоляция тенантов
Шаг 5: main_rag_annotations.dart — связка аннотации + векторы
Шаг 6: Остальные сценарии
```

---

## Конфигурация для запуска

```yaml
# docker-compose.yml — добавить в сервис vector/knowledge:
environment:
  VAULT_ENDPOINT: http://server:8765
  OLLAMA_ENDPOINT: http://172.22.0.1:11434  # хост-машина
  OLLAMA_MODEL: nomic-embed-text
```

```dart
// В сценарии:
final ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] 
    ?? 'http://172.22.0.1:11434';
final model = Platform.environment['OLLAMA_MODEL'] 
    ?? 'nomic-embed-text';
final embedder = OllamaEmbeddingsClient(
  endpoint: ollamaEndpoint,
  model: model,
);
```

---

## Что нужно от хост-машины

1. Запустить Ollama с биндингом на все интерфейсы:
   ```bash
   OLLAMA_HOST=0.0.0.0 ollama serve
   ```

2. Установить модель:
   ```bash
   ollama pull nomic-embed-text
   ```

3. Проверить доступность из контейнера:
   ```bash
   docker run --rm curlimages/curl curl http://172.22.0.1:11434/api/tags
   ```
