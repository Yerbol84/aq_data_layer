# IStorageSchema — План реализации

## Проблема

Сейчас знание о структуре БД размазано по коду:

- Суффиксы таблиц (`_log`, `_versions`, `_current`, `_deleted`) — строки в нескольких местах
- DDL для каждого режима — приватные методы `_createDirectTable`, `_createVersionedTables`, `_createLoggedTables` в `PostgresSchemaDeployer`
- `VersionedStorageContract` — отдельный класс с константами, который знает о структуре, но не является частью контракта типа хранения
- `SchemaDeployer` знает о режимах хранения — нарушение принципа открытости/закрытости (добавить новый режим = менять deployer)

## Цель

Каждый **тип хранения** инкапсулирует всё знание о своей структуре в БД.  
`SchemaDeployer` не знает о режимах — он просто вызывает `schema.deploy(connection)`.  
Клиент (домен) только передаёт имя коллекции — всё остальное наше дело.

## Архитектура

```
lib/deploy/
    i_storage_schema.dart          ← интерфейс + StorageTableNames
    direct_storage_schema.dart     ← Direct: 1 main + 1 deleted
    versioned_storage_schema.dart  ← Versioned: main + versions + current + deleted
    logged_storage_schema.dart     ← Logged: main + log + deleted
    domain_registration.dart       ← добавить schema: IStorageSchema
    schema_deployer.dart           ← ensureSchema принимает IStorageSchema
```

## Интерфейс `IStorageSchema`

```dart
abstract interface class IStorageSchema {
  /// Имя основной коллекции (задаётся клиентом).
  String get collection;

  /// Режим хранения.
  StorageMode get mode;

  /// Все имена таблиц для этого типа хранения — единственный источник правды.
  StorageTableNames get tableNames;

  /// DDL: создать все таблицы, индексы, политики RLS.
  Future<void> deploy(Session connection, List<VaultIndex> indexes);

  /// DDL: валидировать структуру существующих таблиц.
  Future<void> validate(Session connection);
}
```

## `StorageTableNames` — единственный источник правды для имён

```dart
final class StorageTableNames {
  final String main;       // всегда = collection
  final String? deleted;   // всегда = '{collection}_deleted'
  final String? log;       // только Logged: '{collection}_log'
  final String? versions;  // только Versioned: '{collection}_versions'
  final String? current;   // только Versioned: '{collection}_current'

  /// Все таблицы этого типа хранения (для итерации в deployer).
  List<String> get all;
}
```

## Реализации

### `DirectStorageSchema`
Таблицы: `{col}`, `{col}_deleted`  
Индексы: tenant_id + пользовательские  
RLS: tenant isolation на обеих таблицах

### `VersionedStorageSchema`
Таблицы: `{col}_versions`, `{col}_current`, `{col}_deleted`  
Заменяет `VersionedStorageContract` — все константы полей переезжают сюда  
RLS: tenant isolation на всех таблицах

### `LoggedStorageSchema`
Таблицы: `{col}`, `{col}_log`, `{col}_deleted`  
Индекс на `data->>'entityId'` в log таблице  
RLS: tenant isolation на всех таблицах

## Изменения в существующем коде

| Файл | Что меняется |
|------|-------------|
| `domain_registration.dart` | добавить `IStorageSchema get schema` (генерируется из `mode` + `collection`) |
| `postgres_schema_deployer.dart` | `_createDirectTable` / `_createVersionedTables` / `_createLoggedTables` → делегируют в `schema.deploy()` |
| `versioned_storage_contract.dart` | константы полей переезжают в `VersionedStorageSchema`, файл помечается `@Deprecated` |
| `postgres_versioned_repository.dart` | использует `VersionedStorageSchema.tableNames` вместо `VersionedStorageContract.versionsTable()` |

## Что НЕ меняется

- Публичный API `VaultRegistry`, `SchemaDeployer`, `DomainRegistration` — обратная совместимость
- Логика репозиториев — только имена таблиц через `tableNames`
- Клиентский код — регистрация доменов не меняется

## Порядок реализации

1. `i_storage_schema.dart` — интерфейс + `StorageTableNames`
2. `direct_storage_schema.dart` — самый простой, эталон паттерна
3. `versioned_storage_schema.dart` — переносим константы из `VersionedStorageContract`
4. `logged_storage_schema.dart`
5. Обновить `domain_registration.dart` — фабрика `IStorageSchema` из `mode`
6. Обновить `postgres_schema_deployer.dart` — делегирование
7. Обновить `postgres_versioned_repository.dart` — новые имена таблиц
8. Тесты — проверить что все имена таблиц совпадают со старыми (регрессия)

## Критерий готовности

- Нет ни одной строки вида `'${collection}_log'` вне `IStorageSchema` реализаций
- `SchemaDeployer` не содержит `switch` по `StorageMode`
- `VersionedStorageContract` помечен `@Deprecated`
- Все существующие тесты проходят без изменений
