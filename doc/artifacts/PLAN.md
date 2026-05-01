# Document Intelligence — Архитектурный план

> Дата: 2026-04-30  
> Статус: планирование  
> Принцип: каждый слой — независимый патч поверх `aq_data_layer`

---

## Общая картина

```
┌──────────────────────────────────────────────────────────────────┐
│  CLIENT (Flutter / Dart CLI)                                     │
│  import 'package:aq_artifacts/aq_artifacts.dart'                 │
│  import 'package:aq_annotations/aq_annotations.dart'            │
│  import 'package:aq_knowledge/aq_knowledge.dart'                 │
└──────────────────────────────────────────────────────────────────┘
                          ↓ RPC
┌──────────────────────────────────────────────────────────────────┐
│  SERVER (VaultRegistry)                                          │
│  AqDomains.all + ArtifactDomains.all + AnnotationDomains.all    │
│  IVaultSecurityProtocol — применяется ко всем доменам           │
└──────────────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────────────┐
│  STORAGE LAYER                                                   │
│  PostgreSQL (метаданные + аннотации + векторы)                   │
│  IArtifactBackend (байты: Local FS / S3 / PostgreSQL bytea)      │
└──────────────────────────────────────────────────────────────────┘
```

---

## Слой 1: Artifacts (файлы)

### Модели (в `aq_schema`)

```dart
// Метаданные файла — хранится в VaultStorage (Direct)
final class ArtifactEntry implements DirectStorable {
  final String id;
  final String tenantId;
  final String ownerId;
  final String name;           // "report.pdf"
  final String mimeType;       // "application/pdf"
  final int sizeBytes;
  final String storageKey;     // ключ в IArtifactBackend
  final String checksum;       // sha256
  final DateTime createdAt;
  final DateTime? deletedAt;   // soft delete

  static const kCollection = 'artifacts';
}
```

### Интерфейс бэкенда (в `aq_schema`)

```dart
// Только байты — не знает о метаданных
abstract interface class IArtifactBackend {
  Future<String> store(String tenantId, String key, Uint8List bytes, String mimeType);
  Future<Uint8List> retrieve(String tenantId, String key);
  Future<void> delete(String tenantId, String key);
  Future<bool> exists(String tenantId, String key);
}
```

### Реализации бэкенда (в `aq_data_layer`)

| Класс | Где хранит | Когда использовать |
|---|---|---|
| `LocalArtifactBackend` | Файловая система | Dev, desktop apps |
| `PostgresArtifactBackend` | `bytea` колонка | Простой деплой, < 50MB файлы |
| `S3ArtifactBackend` | S3 / MinIO / R2 | Production, большие файлы |
| `MemoryArtifactBackend` | RAM | Тесты |

**По умолчанию:** `LocalArtifactBackend` — работает без настройки.

### Репозиторий

```dart
abstract interface class IArtifactRepository {
  // Загрузить файл (метаданные + байты)
  Future<ArtifactEntry> upload(Uint8List bytes, {
    required String name,
    required String mimeType,
    required String ownerId,
  });

  // Скачать байты
  Future<Uint8List> download(String artifactId);

  // Метаданные
  Future<ArtifactEntry?> findById(String id);
  Future<List<ArtifactEntry>> findAll({VaultQuery? query});

  // Удалить (soft delete метаданных + удалить байты)
  Future<void> delete(String artifactId);
}
```

### Как подключить (патч)

```dart
// В main.dart приложения
import 'package:aq_artifacts/aq_artifacts.dart';

// Зарегистрировать бэкенд (один раз)
IArtifactBackend.register(LocalArtifactBackend(basePath: '/data/artifacts'));
// или
IArtifactBackend.register(S3ArtifactBackend(bucket: 'my-bucket', ...));

// Использовать
final artifacts = IDataLayer.instance.artifacts;
final entry = await artifacts.upload(pdfBytes, name: 'report.pdf', mimeType: 'application/pdf', ownerId: userId);
```

---

## Слой 2: Annotations (разметка документа)

### Модели (в `aq_schema`)

```dart
enum AnnotationActorType { user, llm }

enum AnnotationType {
  highlight,    // выделение текста/области
  comment,      // комментарий
  label,        // тег/метка
  vectorRef,    // ссылка на векторный чанк (LLM)
}

// LoggedStorable — каждое изменение логируется
final class DocumentAnnotation implements LoggedStorable {
  final String id;
  final String tenantId;
  final String ownerId;
  final String artifactId;          // ссылка на ArtifactEntry
  final AnnotationActorType actorType;
  final String actorId;             // userId или llm-model-id
  final AnnotationType type;
  final AnnotationRange range;      // где в документе
  final String? content;            // текст комментария
  final Map<String, dynamic> meta;  // для LLM: chunkId, score, etc.
  final DateTime createdAt;
  final DateTime? deletedAt;

  static const kCollection = 'document_annotations';
  static const kTrackedFields = ['content', 'meta'];
}

final class AnnotationRange {
  final int? page;      // для PDF
  final int startOffset; // символьный offset
  final int endOffset;
  final String? xpath;  // для HTML/XML
}
```

### Почему LoggedStorable

- Пользователь изменил комментарий → история изменений
- LLM обновил метку → можно откатить
- Аудит: кто и когда поставил метку
- Rollback: "верни документ к состоянию до LLM-разметки"

### Как подключить (патч)

```dart
import 'package:aq_annotations/aq_annotations.dart';

final annotations = IDataLayer.instance.logged<DocumentAnnotation>(
  collection: DocumentAnnotation.kCollection,
  fromMap: DocumentAnnotation.fromMap,
);

// Пользователь выделил текст
await annotations.save(DocumentAnnotation(
  artifactId: 'artifact-123',
  actorType: AnnotationActorType.user,
  type: AnnotationType.highlight,
  range: AnnotationRange(page: 3, startOffset: 450, endOffset: 520),
  content: 'Важный момент',
), actorId: userId);

// LLM поставил метку
await annotations.save(DocumentAnnotation(
  artifactId: 'artifact-123',
  actorType: AnnotationActorType.llm,
  type: AnnotationType.vectorRef,
  range: AnnotationRange(page: 3, startOffset: 450, endOffset: 520),
  meta: {'chunkId': 'chunk-42', 'score': 0.94, 'query': 'revenue growth'},
), actorId: 'gpt-4o');
```

---

## Слой 3: Vectors (семантический индекс)

### Модели (в `aq_schema`)

```dart
final class VectorChunk implements DirectStorable {
  final String id;
  final String tenantId;
  final String artifactId;      // из какого документа
  final int chunkIndex;         // порядок в документе
  final String text;            // исходный текст чанка
  final List<double> embedding; // вектор (1536 dim для OpenAI)
  final String? annotationId;   // связанная аннотация (опционально)
  final Map<String, dynamic> meta; // page, offset, model, etc.

  static const kCollection = 'vector_chunks';
}
```

### Интерфейс embeddings (в `aq_schema`)

```dart
abstract interface class IEmbeddingsClient {
  Future<List<double>> embed(String text);
  Future<List<List<double>>> embedBatch(List<String> texts);
  int get dimensions; // 1536, 768, etc.
}

// Реализации:
// OpenAIEmbeddingsClient
// OllamaEmbeddingsClient  (локальный)
// MockEmbeddingsClient    (для тестов)
```

### VectorRepository (расширение существующего)

```dart
abstract interface class IVectorRepository {
  Future<void> upsert(VectorChunk chunk);
  Future<List<VectorSearchResult>> search(
    List<double> queryEmbedding, {
    int topK = 10,
    double minScore = 0.7,
    String? artifactId,  // поиск только в конкретном документе
  });
}

final class VectorSearchResult {
  final VectorChunk chunk;
  final double score;
  final String? annotationId; // если есть — показать пользователю место в документе
}
```

---

## Слой 4: Knowledge Pipeline (файл → векторы)

```dart
abstract interface class IKnowledgePipeline {
  // Полный pipeline: загрузить файл + создать векторы
  Future<KnowledgeIndexResult> index(Uint8List bytes, {
    required String name,
    required String mimeType,
    required String ownerId,
    int chunkSize = 512,
    int chunkOverlap = 64,
  });
}

final class KnowledgeIndexResult {
  final ArtifactEntry artifact;
  final int chunksCreated;
  final Duration processingTime;
}
```

### Поддерживаемые форматы (v1)

| Формат | Chunker |
|---|---|
| `.md`, `.txt` | `TextChunker` — по параграфам |
| `.pdf` | `PdfChunker` — по страницам/параграфам |
| `.dart`, `.py`, `.ts` | `CodeChunker` — по функциям/классам |

---

## Связь слоёв

```
ArtifactEntry ──────────────────────────────────────────┐
     │                                                   │
     ├── DocumentAnnotation (user)                       │
     │        └── range: {page: 3, offset: 450-520}     │
     │                                                   │
     ├── DocumentAnnotation (llm: vectorRef)             │
     │        └── annotationId ──────────────────────┐  │
     │                                               │  │
     └── VectorChunk[]                               │  │
              └── annotationId ────────────────────→─┘  │
              └── artifactId ──────────────────────────→─┘

Поиск: query → embedding → VectorChunk → annotationId → DocumentAnnotation → range
Показ: открыть ArtifactEntry, выделить range из DocumentAnnotation
```

---

## Порядок реализации

```
Шаг 1: IArtifactBackend в aq_schema + LocalArtifactBackend в aq_data_layer
Шаг 2: ArtifactEntry (DirectStorable) + ArtifactRepository
Шаг 3: Добавить в AqDomains.all + сервер подхватывает
Шаг 4: DocumentAnnotation (LoggedStorable) + добавить в домены
Шаг 5: IEmbeddingsClient + MockEmbeddingsClient
Шаг 6: PostgresVectorRepository (pgvector)
Шаг 7: TextChunker + KnowledgePipeline
Шаг 8: Сценарии: upload → annotate → index → search → show location
```

---

## Что НЕ делаем в data layer

- Рендеринг документов (PDF viewer, markdown renderer) — клиентская задача
- Редактирование документов — клиентская задача, data layer только хранит
- Конкретные LLM вызовы — это `aq_llm` пакет
- UI для аннотаций — это `aq_studio` пакет

---

## Backward compatibility

Все изменения — только добавление. Ничего не ломается:
- Новые домены в `AqDomains.all` — сервер создаёт новые таблицы
- `IArtifactBackend` — новый интерфейс, не затрагивает существующий код
- `IEmbeddingsClient` — новый интерфейс
- Существующие Direct/Versioned/Logged репозитории — не трогаем
