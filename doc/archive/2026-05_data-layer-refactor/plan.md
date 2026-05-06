# Plan: aq_data_layer — архитектурный рефакторинг

## Шаги

1. Удалить `lib/repositories/repository.dart`
2. Удалить `lib/repositories/artifact_repository.dart`, `vector_repository.dart`, `knowledge_repository.dart`
3. `ArtifactRepositoryImpl`: заменить `implements ArtifactRepository<T>` → `implements IArtifactRepository<T>`, убрать import старого интерфейса
4. `KnowledgeRepositoryImpl`: заменить `implements KnowledgeRepository<T>` → `implements IKnowledgeRepository<T>`, убрать import старого интерфейса
5. Создать `SimpleVectorRepositoryImpl implements IVectorRepository` — тонкая обёртка над `VectorStorage` для одной коллекции
6. Добавить `artifacts()`, `vectors()`, `knowledge()` в `DataLayerImpl`
7. Обновить экспорты в `dart_vault.dart` и `server.dart`
8. `dart analyze` — 0 errors

## Definition of Done
- `dart analyze` → 0 errors
- Логика реализаций не изменена
- `IDataLayer.instance.artifacts/vectors/knowledge()` работают
