# dart_vault — Data Layer для AQ экосистемы

**Версия:** 0.5.0  
**Статус:** Production Ready ✅  
**dart analyze:** 0 errors, 0 warnings  
**Тестов:** 100/100 ✅

---

## Что это

`dart_vault` — типизированный data layer поверх PostgreSQL для Dart/Flutter приложений.

**Три слоя хранения:**
- **VaultStorage** — документы (Direct / Versioned / Logged)
- **ArtifactStorage** — бинарные файлы (байты)
- **VectorStorage** — векторные эмбеддинги (ANN-поиск + hybrid)

**Архитектура:** тонкий клиент + RPC сервер. Клиент не знает о БД.

---

## Быстрый старт

### 1. Запустить стек

```bash
cd example/stack
docker-compose up -d
# Поднимает: postgres (pgvector) + ollama + server
```

### 2. Клиент

```dart
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  await initializeDataLayer(
    endpoint: 'http://localhost:8765',
    tenantId: 'my-tenant',
    authToken: 'my-token',
  );

  // Direct — простой CRUD
  final projects = IDataLayer.instance.direct<MyProject>(
    collection: 'projects',
    fromMap: MyProject.fromMap,
  );
  await projects.save(project);

  // Versioned — с ветками и историей
  final graphs = IDataLayer.instance.versioned<WorkflowGraph>(
    collection: WorkflowGraph.kCollection,
    fromMap: WorkflowGraph.fromMap,
  );
  final node = await graphs.createEntity(graph);
  await graphs.publishDraft(node.nodeId);

  // Logged — с audit trail
  final annotations = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );
  await annotations.save(annotation, actorId: userId);
  final history = await annotations.getHistory(annotationId);
}
```

### 3. Файлы (Artifacts)

```dart
// Upload bytes
final remote = RemoteVaultStorage(endpoint: endpoint, tenantId: tenantId);
await remote.connect();
final artifacts = RemoteArtifactStorage(remote: remote);
await artifacts.put('tenant/doc-001/file.pdf', pdfBytes, contentType: 'application/pdf');

// Save metadata
final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
  collection: StoredArtifact.kCollection,
  fromMap: StoredArtifact.fromMap,
);
await artifactRepo.save(StoredArtifact(
  id: 'doc-001',
  tenantId: tenantId,
  ownerId: userId,
  storageKey: 'tenant/doc-001/file.pdf',
  fileName: 'report.pdf',
  contentType: 'application/pdf',
  sizeBytes: pdfBytes.length,
  checksum: sha256(pdfBytes),
  createdAt: DateTime.now().toUtc(),
));
```

### 4. Векторный поиск

```dart
// Настройка pipeline
final embedder = OllamaEmbeddingsClient(
  endpoint: 'http://localhost:11434',
  model: 'nomic-embed-text',
  dimensions: 768,
);

final registry = VectorStoreRegistryImpl();
registry.register(
  VectorStoreDescriptor(id: 'pgvector-main', type: 'pgvector',
      embedderId: embedder.id, vectorDim: 768),
  RemoteVectorStorage(remote: remote),
);

final vectorRepo = VectorRepositoryImpl(registry: registry);

// Индексировать документ
await vectorRepo.index(
  artifact,
  fileBytes,
  IndexingPipeline(
    id: 'my-pipeline',
    storeId: 'pgvector-main',
    extractor: PlainTextExtractor(),
    chunker: SentenceChunker(maxChunkChars: 500),
    embedder: embedder,
    reranker: PassthroughReranker(),
  ),
);

// Семантический поиск
final results = await vectorRepo.search(
  'how does vector similarity work',
  tenantId: tenantId,
  storeId: 'pgvector-main',
  embedder: embedder,
  topK: 5,
);

// Hybrid search (dense + BM25)
final hybridResults = await vectorRepo.search(
  'SQL injection prevention',
  tenantId: tenantId,
  storeId: 'pgvector-main',
  embedder: embedder,
  sparseQuery: 'SQL injection prevention',
  alpha: 0.7, // 70% dense + 30% BM25
);
```

---

## Сервер

```dart
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  final pool = Pool.withEndpoints([Endpoint(host: dbHost, ...)]);

  // Vector storage
  final vectorStorage = PgVectorStorage(pool: pool);
  final vectorRegistry = VectorStoreRegistryImpl();
  vectorRegistry.register(
    VectorStoreDescriptor(id: 'pgvector-main', type: 'pgvector',
        embedderId: 'ollama-nomic-embed-text', vectorDim: 768),
    vectorStorage,
  );

  // Security
  IVaultSecurityProtocol.initialize(MockVaultSecurityProtocol()); // dev
  // IVaultSecurityProtocol.initialize(MyProductionProtocol());   // prod

  final registry = VaultRegistry(
    storageFactory: (tenantId) => PostgresVaultStorage(pool: pool, tenantId: tenantId),
    deployer: PostgresSchemaDeployer(pool: pool),
    artifactBackend: LocalArtifactStorage(basePath: '/data/artifacts'),
    vectorRegistry: vectorRegistry,
  );

  for (final domain in AqDomains.all) {
    registry.register(DomainRegistration(
      collection: domain.collection,
      mode: _toStorageMode(domain.kind),
      fromMap: domain.fromMap,
      indexes: domain.indexes,
      jsonSchema: const {'type': 'object'},
    ));
  }

  await registry.deploy();
}
```

---

## Docker стек

```yaml
# example/stack/docker-compose.yml
services:
  postgres:   # pgvector/pgvector:pg15 — всегда запущен
  ollama:     # ollama/ollama:latest — всегда запущен
  server:     # dart_vault сервер — всегда запущен
```

```bash
# Запустить стек
docker-compose up -d

# Установить модель эмбеддингов
docker exec stack-ollama-1 ollama pull nomic-embed-text

# Запустить сценарий
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  -e OLLAMA_ENDPOINT=http://stack-ollama-1:11434 \
  stack-search_core
```

### Переменные окружения сервера

| Переменная | По умолчанию | Описание |
|---|---|---|
| `DB_HOST` | `localhost` | PostgreSQL хост |
| `DB_PORT` | `5432` | PostgreSQL порт |
| `DB_NAME` | `vault_db` | Имя БД |
| `SERVER_PORT` | `8765` | Порт сервера |
| `ARTIFACT_PATH` | — | Путь для файлов (если не задан — файлы не хранятся) |
| `SECURITY_MODE` | — | `mock` для тестов, пусто — без security |
| `VECTOR_DIM` | `768` | Размерность векторов |
| `VECTOR_EMBEDDER_ID` | `ollama-nomic-embed-text` | ID embedder'а |

---

## Примеры

Все примеры в `example/stack/console_client/`:

| Файл | Описание |
|---|---|
| `main_artifacts.dart` | Upload, metadata, annotations, download |
| `main_vector.dart` | Full vector pipeline, remote RPC |
| `main_knowledge.dart` | Upload+index+annotate+search |
| `main_rag_basic.dart` | RAG с Ollama nomic-embed-text |
| `main_search_core.dart` | Dense search, filter, tenant isolation, scores |
| `main_search_precision.dart` | Precision@K, MRR evaluation |
| `main_search_lifecycle.dart` | Index→Reindex→Delete |
| `main_search_concurrent.dart` | Параллельная индексация |
| `main_search_chunking.dart` | Сравнение стратегий чанкования |
| `main_search_reranker.dart` | Reranker evaluation |
| `main_integration_rag.dart` | Context assembly для RAG |
| `main_integration_annotations.dart` | chunkId→annotation→span |
| `main_search_migration.dart` | Миграция между embedder'ами |
| `main_perf_latency.dart` | Latency benchmark |
| `main_security.dart` | Security gate scenarios |
| `main_stress.dart` | Stress scenarios |

---

## Архитектура

```
aq_schema (интерфейсы и модели)
  ├── IDataLayer — мультитон data layer
  ├── VaultStorage — document storage interface
  ├── ArtifactStorage — binary storage interface
  ├── VectorStorage — vector search interface (+ hybrid)
  ├── IChunker, IEmbeddingsClient, IReranker — pipeline interfaces
  └── StoredArtifact, DocumentAnnotation, IndexingPipelineRecord, ...

aq_data_layer (реализации)
  ├── PostgresVaultStorage — documents in PostgreSQL
  ├── PgVectorStorage — vectors in pgvector (+ tsvector hybrid)
  ├── LocalArtifactStorage — files on disk
  ├── InMemoryVectorStorage — vectors in RAM (dev/test)
  ├── SentenceChunker — sentence-boundary chunking
  ├── OllamaEmbeddingsClient — Ollama HTTP embeddings
  ├── OllamaReranker — cross-encoder reranking
  └── RemoteVectorStorage — client-side RPC transport
```

---

## Документация

| Документ | Описание |
|---|---|
| [doc/SESSION_2026_05_01.md](doc/SESSION_2026_05_01.md) | Отчёт текущей сессии |
| [doc/vector/ARCHITECTURE.md](doc/vector/ARCHITECTURE.md) | Архитектура vector layer |
| [doc/scenarios/SCENARIOS.md](doc/scenarios/SCENARIOS.md) | Описание всех сценариев |
| [doc/scenarios/REPORT.md](doc/scenarios/REPORT.md) | Результаты прогона сценариев |
| [doc/tech_debt/TECH_DEBT.md](doc/tech_debt/TECH_DEBT.md) | Технический долг |
| [doc/use_cases/VECTOR_USE_CASES.md](doc/use_cases/VECTOR_USE_CASES.md) | Use cases векторной БД |
| [doc/guides/USAGE_GUIDE.md](doc/guides/USAGE_GUIDE.md) | Полное руководство |
| [doc/architecture/ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md) | Общая архитектура |

---

## Технический долг

Полный список: [doc/tech_debt/TECH_DEBT.md](doc/tech_debt/TECH_DEBT.md)

Приоритетные:
- 🔴 `OllamaEmbeddingsClient` — реализован. `OpenAiEmbeddingsClient` — нет
- 🔴 `PdfExtractor` — нет (только `text/*`)
- 🟡 `Vault.vectorRepository()` — удобный фасад не реализован
- 🟡 `embedBatch` лимиты (OpenAI max 2048)
