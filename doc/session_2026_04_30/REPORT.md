# Сессия 2026-04-30 — Отчёт о работе

**Статус:** ✅ Завершено  
**Стек:** Direct ✅ Versioned ✅ Logged (включая rollbackTo) ✅

---

## Что было сделано

### 1. IStorageSchema — инкапсуляция DDL типов хранения

**Проблема:** DDL для каждого режима хранения был размазан по `PostgresSchemaDeployer` в виде приватных методов. Суффиксы таблиц (`_log`, `_versions`, `_current`, `_deleted`) — строки в нескольких местах.

**Решение:** Каждый тип хранения инкапсулирует весь свой DDL.

Новые файлы:
- `lib/deploy/i_storage_schema.dart` — интерфейс + `StorageTableNames`
- `lib/deploy/direct_storage_schema.dart`
- `lib/deploy/versioned_storage_schema.dart` (заменил `VersionedStorageContract`)
- `lib/deploy/logged_storage_schema.dart`

`PostgresSchemaDeployer._createTablesForDomain()` теперь: `domain.schema.deploy(connection, indexes)` — нет switch по режимам.

Подробнее: `doc/storage_schema/PLAN.md` + `doc/storage_schema/REPORT.md`

---

### 2. Typed Transport Layer — типизированные команды

**Проблема:** Операции передавались как строки в Map: `put(col, id, {'operation': 'createBranch', ...})`. Два независимых списка операций (`_allowedOperations` + `switch`) расходились → баги в рантайме.

**Решение:** Типизированные команды + Map-based диспетчер.

Новые файлы в `aq_schema/lib/data_layer/transport/`:
- `i_vault_command.dart`, `i_vault_query.dart`
- `versioned_commands.dart` — 7 команд + 3 запроса
- `logged_commands.dart` — RollbackToCommand + GetHistoryQuery

`lib/deploy/vault_command_dispatcher.dart` — `Map<String, Handler>` вместо `switch` + `_allowedOperations`.

`RemoteVaultStorage` получил `sendCommand()` + `sendQuery()`.

Подробнее: `doc/transport/PLAN.md` + `doc/transport/REPORT.md`

---

### 3. Repository per Transport — RemoteLoggedRepository

**Проблема:** `LoggedRepositoryImpl` содержал `if(is ProxyStorage)` ветки — один класс обслуживал и клиент и сервер. `rollbackTo` делал `put` на `_log` коллекцию через remote → сервер не знал как обработать.

**Решение:** Разные реализации для разных транспортов.

- `RemoteLoggedRepository` — тонкий клиент, только RPC, не знает о `_log` таблицах
- `LoggedRepositoryImpl` — чистая локальная логика, нет `if(is ProxyStorage)`
- `Vault.logged()` — одно место выбора реализации

---

### 4. Исправленные баги

| Баг | Причина | Фикс |
|-----|---------|------|
| `getVersionNode` Unknown operation | Не в `_allowedOperations` | Удалён `_allowedOperations`, заменён диспетчером |
| `createBranch` type cast error | Неправильная структура args | `CreateBranchCommand` с явными полями |
| `rollbackTo` not supported for log collections | `LoggedRepositoryImpl` на клиенте писал в `_log` напрямую | `RemoteLoggedRepository` |
| `getStateAt` null cast | `_computeDiff` при `created` не включал все поля | `effectiveTracked = null` при `before == null` |
| `WorkflowRun.fromMap` null cast | `graphSnapshot` не nullable | Защитный `?? const {}` |
| `LoggedStorable.snapshot` при rollback | snapshot не сохранялся при `created` | Всегда snapshot при `LogOperation.created` |

---

## Итоговая архитектура

```
Клиент                              Сервер
Vault.logged()                      VaultRegistry._dispatchLogged()
  → RemoteLoggedRepository            → VaultCommandDispatcher
      rollbackTo()                        handlers['rollbackTo']
        → sendCommand(                      → LoggedRepositoryImpl
            RollbackToCommand(...)              → local SQL logic
          )
```

```
DomainRegistration.schema           PostgresSchemaDeployer
  → DirectStorageSchema               → schema.deploy(connection, indexes)
  → VersionedStorageSchema            (нет switch по режимам)
  → LoggedStorageSchema
```

---

## Сценарии (все проходят)

```
1. DIRECT — AqStudioProject    ✅ save, findById, update, findAll, findPage, delete
2. DIRECT — GraphRunState      ✅ save, findAll, update, delete
3. VERSIONED — WorkflowGraph   ✅ create, update, publish, branch, grants, delete
4. LOGGED — WorkflowRun        ✅ save, history, rollbackTo, delete
```
