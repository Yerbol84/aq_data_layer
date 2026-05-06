# Plan: Сценарии для всех типов хранения в трёх режимах

## Структура файлов

```
example/scenarios/
├── pubspec.yaml                    # отдельный пакет
├── README.md                       # навигация по сценариям
│
├── direct/
│   ├── s1_crud/
│   │   ├── mock.dart               # режим 1: MockDataLayer
│   │   ├── local_db.dart           # режим 2: PostgreSQL напрямую
│   │   └── remote.dart             # режим 3: HTTP RPC
│   ├── s2_filter_pagination/
│   │   ├── mock.dart
│   │   ├── local_db.dart
│   │   └── remote.dart
│   └── s3_soft_delete_restore/
│       ├── mock.dart
│       ├── local_db.dart
│       └── remote.dart
│
├── versioned/
│   ├── s1_lifecycle/
│   ├── s2_branching/
│   └── s3_rollback/
│
├── logged/
│   ├── s1_audit_trail/
│   ├── s2_rollback/
│   └── s3_collection_log/
│
├── artifact/
│   ├── s1_upload_download/
│   ├── s2_metadata_query/
│   └── s3_replace/
│
└── vector/
    ├── s1_index_search/
    ├── s2_hybrid_search/
    └── s3_reindex/
```

## Шаги реализации

1. Создать `example/scenarios/pubspec.yaml`
2. Direct: s1, s2, s3 (×3 режима = 9 файлов)
3. Versioned: s1, s2, s3 (×3 = 9 файлов)
4. Logged: s1, s2, s3 (×3 = 9 файлов)
5. Artifact: s1, s2, s3 (×3 = 9 файлов)
6. Vector: s1, s2, s3 (×3 = 9 файлов)
7. README.md с навигацией
8. `dart analyze example/scenarios/` → 0 errors
9. report.md

## Принципы написания примеров

- Каждый файл — самодостаточный `main()`, запускается отдельно
- Mock режим: `import 'package:aq_schema/data_testing.dart'`
- Local DB режим: `import 'package:dart_vault/server.dart'` + PostgresVaultStorage
- Remote режим: `import 'package:dart_vault/dart_vault.dart'` + `IDataLayer.initialize(endpoint)`
- Один и тот же бизнес-сценарий во всех трёх файлах — только инициализация разная
- Комментарии объясняют что происходит

## Definition of Done
- 45 файлов (15 сценариев × 3 режима)
- `dart analyze example/scenarios/` → 0 errors
- README с таблицей навигации
