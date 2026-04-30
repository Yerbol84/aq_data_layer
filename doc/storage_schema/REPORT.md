# IStorageSchema — Отчёт о реализации

**Дата:** 2026-04-30  
**Статус:** ✅ Завершено

---

## Что было сделано

### Новые файлы

| Файл | Описание |
|------|----------|
| `lib/deploy/i_storage_schema.dart` | Интерфейс `IStorageSchema` + `StorageTableNames` |
| `lib/deploy/direct_storage_schema.dart` | DDL для Direct хранения |
| `lib/deploy/versioned_storage_schema.dart` | DDL для Versioned хранения + все константы полей |
| `lib/deploy/logged_storage_schema.dart` | DDL для Logged хранения |

### Изменённые файлы

| Файл | Что изменилось |
|------|----------------|
| `lib/deploy/domain_registration.dart` | Добавлен `IStorageSchema get schema` — фабрика из `mode` |
| `lib/storage/postgres/postgres_schema_deployer.dart` | `_createTablesForDomain` делегирует в `schema.deploy()`. Удалены `_createDirectTable`, `_createVersionedTables`, `_createLoggedTables`, `_createDeletedTable`, `_createIndexes`, `_enableRls` |
| `lib/storage/postgres/postgres_versioned_repository.dart` | 105 замен `VersionedStorageContract` → `VersionedStorageSchema`. Инициализация таблиц через `schema.tableNames` |
| `lib/storage/versioned_storage_contract.dart` | Помечен `@Deprecated` |

---

## Архитектура

```
IStorageSchema
    ├── collection: String          ← задаётся клиентом
    ├── mode: StorageMode           ← тип хранения
    ├── tableNames: StorageTableNames  ← единственный источник правды
    └── deploy(Session, indexes)    ← весь DDL здесь

StorageTableNames
    ├── main       → '{collection}'
    ├── deleted    → '{collection}_deleted'
    ├── log?       → '{collection}_log'         (только Logged)
    ├── versions?  → '{collection}_versions'    (только Versioned)
    └── current?   → '{collection}_current'     (только Versioned)
```

### Каждый тип хранения знает свои таблицы

```
DirectStorageSchema    → main + deleted
VersionedStorageSchema → versions + current + deleted
LoggedStorageSchema    → main + log + deleted
```

---

## Критерии готовности

- ✅ Нет строк вида `'${collection}_log'` вне реализаций `IStorageSchema`
- ✅ `SchemaDeployer` не содержит `switch` по `StorageMode`
- ✅ `VersionedStorageContract` помечен `@Deprecated`
- ✅ Все имена таблиц через `schema.tableNames` — нет хардкода снаружи
- ✅ Обратная совместимость сохранена — публичный API не изменился

---

## Как добавить новый тип хранения

1. Создать `MyStorageSchema implements IStorageSchema` в `lib/deploy/`
2. Добавить кейс в `DomainRegistration.schema` switch
3. Добавить `StorageMode.myMode` в `StorageMode` enum (в `aq_schema`)

`SchemaDeployer` и `VaultRegistry` изменять не нужно.

---

## Связанные документы

- [PLAN.md](PLAN.md) — план реализации
- `lib/deploy/i_storage_schema.dart` — интерфейс
- `lib/deploy/versioned_storage_schema.dart` — константы полей (замена VersionedStorageContract)
