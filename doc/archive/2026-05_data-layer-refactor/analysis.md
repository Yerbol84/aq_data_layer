# Analysis: aq_data_layer — архитектурный рефакторинг

## Текущее состояние

### Нарушения (перенесены из сессии aq_schema)

1. `lib/repositories/repository.dart` — лишний базовый интерфейс, не используется
2. `lib/repositories/artifact_repository.dart` — интерфейс `ArtifactRepository` в пакете (должен быть `IArtifactRepository` в aq_schema) ✅ уже перенесён
3. `lib/repositories/vector_repository.dart` — интерфейс `VectorRepository` в пакете ✅ уже перенесён
4. `lib/repositories/knowledge_repository.dart` — интерфейс `KnowledgeRepository` + модели в пакете ✅ уже перенесён
5. `DataLayerImpl` не реализует методы `artifacts()`, `vectors()`, `knowledge()`

### Реализации

- `ArtifactRepositoryImpl` — `implements ArtifactRepository<T>` → нужно `implements IArtifactRepository<T>`
- `VectorRepositoryImpl` — не реализует никакой интерфейс (pipeline orchestrator)
- `KnowledgeRepositoryImpl` — `implements KnowledgeRepository<T>` → нужно `implements IKnowledgeRepository<T>`

### Логика не меняется

Только переключение `implements` и удаление старых файлов-интерфейсов.
`VectorRepositoryImpl` остаётся как есть — это pipeline orchestrator, не репозиторий.
Для `IVectorRepository` нужна отдельная простая реализация поверх `VectorStorage`.

## Ограничения

- Логика реализаций не меняется
- Только архитектурные изменения: imports, implements, новые методы в DataLayerImpl
