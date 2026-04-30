# Typed Transport Layer — Отчёт о реализации

**Дата:** 2026-04-30  
**Статус:** ✅ Завершено. Все сценарии проходят.

---

## Что было сделано

### Новые файлы

| Файл | Описание |
|------|----------|
| `aq_schema/lib/data_layer/transport/i_vault_command.dart` | Интерфейс типизированной команды |
| `aq_schema/lib/data_layer/transport/i_vault_query.dart` | Интерфейс типизированного запроса |
| `aq_schema/lib/data_layer/transport/versioned_commands.dart` | 7 команд + 3 запроса для Versioned |
| `aq_schema/lib/data_layer/transport/logged_commands.dart` | RollbackToCommand + GetHistoryQuery |
| `aq_data_layer/lib/deploy/vault_command_dispatcher.dart` | Map-based диспетчер вместо switch |

### Изменённые файлы

| Файл | Что изменилось |
|------|----------------|
| `aq_schema/lib/aq_schema.dart` | Экспорт transport типов |
| `lib/client/remote/remote_vault_storage.dart` | `sendCommand()` + `sendQuery()` |
| `lib/client/remote/remote_logged_repository.dart` | Переписан: тонкий клиент, только RPC |
| `lib/client/vault.dart` | `logged()` выбирает `RemoteLoggedRepository` для remote |
| `lib/deploy/vault_registry.dart` | `_allowedOperations` удалён, `switch` → `VaultCommandDispatcher` |
| `lib/storage/versioned_repository_impl.dart` | `put(...operation...)` → `sendCommand()` |
| `lib/storage/logged_repository_impl.dart` | Убраны все `if(is ProxyStorage)`, чистая локальная логика |
| `aq_schema/lib/graph/engine/workflow_run.dart` | `graphSnapshot` nullable в `fromMap` |

### Исправленные баги

1. `_allowedOperations` не синхронизирован с dispatch → удалён, заменён диспетчером
2. `createBranch` передавал неправильную структуру args → типизированная команда
3. `rollbackTo` делал `put` на `_log` коллекцию через remote → `RemoteLoggedRepository`
4. `getStateAt` не мог восстановить состояние без snapshot → `_computeDiff` при `created` включает все поля

---

## Архитектура после

```
Клиент (remote)                    Сервер
RemoteLoggedRepository             LoggedRepositoryImpl
  rollbackTo()                       rollbackTo()
    → sendCommand(                     → local SQL logic
        RollbackToCommand(...)           → _storage.put(_logCollection, ...)
      )
    → rpc('rollbackTo', args)
    → HTTP POST /v1/vault/rpc
                                   VaultCommandDispatcher
                                     handlers['rollbackTo'](args)
                                     → repo.rollbackTo(...)
```

**Одно место принятия решения** — `Vault.logged()`:
```dart
return base is RemoteVaultStorage
    ? RemoteLoggedRepository(...)   // тонкий клиент
    : LoggedRepositoryImpl(...);    // локальная логика
```

---

## Критерии готовности

- ✅ Нет `{'operation': 'createBranch', ...}` в клиентском коде
- ✅ `_allowedOperations` удалён
- ✅ `switch(operation)` в `VaultRegistry` заменён на `VaultCommandDispatcher`
- ✅ `LoggedRepositoryImpl` не содержит `if(is ProxyStorage)`
- ✅ Сценарии: Direct ✅ Versioned ✅ Logged (включая rollbackTo) ✅

---

## Связанные документы

- [PLAN.md](PLAN.md) — план реализации
- `aq_schema/lib/data_layer/transport/` — типизированные команды
- `lib/deploy/vault_command_dispatcher.dart` — диспетчер
