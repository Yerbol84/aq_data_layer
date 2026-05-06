# Report: aq_data_layer — архитектурный рефакторинг

## Что сделано

**Удалены старые интерфейсы из пакета:**
- `lib/repositories/repository.dart`
- `lib/repositories/artifact_repository.dart`
- `lib/repositories/vector_repository.dart`
- `lib/repositories/knowledge_repository.dart`

**Обновлены реализации:**
- `ArtifactRepositoryImpl` → `implements IArtifactRepository<T>` (из aq_schema)
- `KnowledgeRepositoryImpl` → `implements IKnowledgeRepository<T>` (из aq_schema)
- `SimpleVectorRepositoryImpl` → `implements IVectorRepository` (из aq_schema)
- `TextSplitter` → `ITextSplitter` (переименован в aq_schema)

**DataLayerImpl расширен:**
- `artifacts<T>()` → `IArtifactRepository<T>`
- `vectors()` → `IVectorRepository`
- `knowledge<T>()` → `IKnowledgeRepository<T>`

**Обновлены фасады:**
- `ArtifactVault.artifacts()` возвращает `IArtifactRepository<T>`
- `KnowledgeVault.documents()` возвращает `IKnowledgeRepository<T>`
- `KnowledgeVault.vectors()` возвращает `IVectorRepository`
- `dart_vault.dart` экспортирует новые интерфейсы из aq_schema

## Результат проверки

```
dart analyze lib/ (наши файлы) → 0 errors
```

Pre-existing ошибки в `storage/postgres/` и `deploy/` (пакет `postgres` не установлен в среде анализа) — не связаны с данной работой.

## Логика не изменена

Все реализации сохранили оригинальную логику. Изменены только:
- `implements` декларации
- `import` директивы
- Возвращаемые типы публичных методов
