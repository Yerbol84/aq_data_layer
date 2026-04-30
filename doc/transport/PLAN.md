# Typed Transport Layer — План реализации

## Причины (почему сейчас плохо)

### 1. Операция спрятана в данных
```dart
// Клиент
storage.put(collection, id, {
  'operation': 'createBranch',  // ← операция как строка в Map
  ...node.toMap(),              // ← структура args нигде не описана
});
```
`put()` используется как универсальный транспорт для произвольных команд. Это нарушение Single Responsibility — `put` должен только сохранять данные.

### 2. Два независимых списка операций
```dart
_allowedOperations = {'createBranch', 'updateDraft', ...}  // список 1
switch(operation) { case 'createBranch': ... }             // список 2
```
Добавил операцию в dispatch — забыл в allowedOperations → баг в рантайме. Именно это и произошло при запуске сценариев.

### 3. Нет типизации args
```dart
// Сервер
final model = reg.fromMap(args['data'] as Map<String, dynamic>)  // падает если data — String
```
Структура `args` для каждой операции нигде не описана. Компилятор не помогает. Ошибки только в рантайме.

### 4. Клиент и сервер — один пакет, но общаются через строки
Оба написаны на Dart, оба в `aq_data_layer`. Но вместо типизированных объектов гоняют `Map<String, dynamic>` со строковыми ключами. Это уровень динамических языков, не Dart.

---

## Стратегические цели

1. **Один источник правды для операций** — список операций = список классов команд. Нельзя добавить операцию на сервере не добавив её на клиенте и наоборот.

2. **Ошибки на этапе компиляции, не рантайма** — неправильные args = ошибка компилятора.

3. **Map вместо switch** — `Map<String, CommandHandler>` вместо `switch(operation)`. O(1) lookup, нет дублирования, легко расширять.

4. **Разделение CRUD и команд** — `put/get/delete` только для прямого хранения. Все специальные операции (versioned, logged) — через типизированные команды.

---

## Архитектура

```
aq_schema/lib/data_layer/transport/
    i_vault_command.dart          ← IVaultCommand (интерфейс команды)
    i_vault_query.dart            ← IVaultQuery (интерфейс запроса)
    versioned/
        create_entity_command.dart
        update_draft_command.dart
        publish_draft_command.dart
        snapshot_command.dart
        create_branch_command.dart
        merge_to_main_command.dart
        get_version_query.dart
        list_versions_query.dart
    logged/
        get_history_query.dart
        rollback_to_command.dart

aq_data_layer/lib/
    client/remote/
        remote_vault_storage.dart   ← добавить sendCommand(IVaultCommand)
    deploy/
        vault_command_dispatcher.dart  ← Map<String, CommandHandler>
```

### Интерфейсы (в aq_schema)

```dart
abstract interface class IVaultCommand {
  String get commandName;           // ключ в Map диспетчера
  Map<String, dynamic> toArgs();    // сериализация для HTTP
}

abstract interface class IVaultQuery {
  String get queryName;
  Map<String, dynamic> toArgs();
}
```

### Диспетчер (в aq_data_layer)

```dart
// Вместо switch + _allowedOperations
final class VaultCommandDispatcher {
  final Map<String, Future<dynamic> Function(Map<String, dynamic> args)> _handlers = {};

  void register(String commandName, Future<dynamic> Function(Map<String, dynamic>) handler) {
    _handlers[commandName] = handler;
  }

  Future<dynamic> dispatch(String commandName, Map<String, dynamic> args) {
    final handler = _handlers[commandName];
    if (handler == null) throw UnknownOperationException(commandName);
    return handler(args);
  }
}
```

### Клиент

```dart
// Вместо: storage.put(col, id, {'operation': 'createBranch', ...})
// После:
await storage.sendCommand(collection, CreateBranchCommand(
  parentNodeId: parentNodeId,
  branchName: branchName,
  data: model.toMap(),
));
```

---

## Порядок реализации

1. `IVaultCommand` + `IVaultQuery` в `aq_schema/lib/data_layer/transport/`
2. Команды для Versioned операций (7 команд)
3. Команды для Logged операций (2 команды)
4. `VaultCommandDispatcher` в `aq_data_layer/lib/deploy/`
5. `sendCommand()` в `RemoteVaultStorage`
6. Обновить `VersionedRepositoryImpl` — использовать команды вместо `put(...operation...)`
7. Обновить `VaultRegistry` — заменить `switch` + `_allowedOperations` на `VaultCommandDispatcher`
8. Тест: прогнать все сценарии

---

## Что НЕ меняется

- Публичный API репозиториев (`VersionedRepository`, `LoggedRepository`) — клиентский код не трогаем
- CRUD операции (`put/get/delete/query`) — остаются как есть, только для прямого хранения
- `DomainRegistration`, `SchemaDeployer`, `IStorageSchema` — не затрагиваются

---

## Критерий готовности

- Нет строк вида `{'operation': 'createBranch', ...}` в клиентском коде
- `_allowedOperations` удалён
- `switch(operation)` в `VaultRegistry` заменён на `dispatcher.dispatch()`
- Все сценарии проходят: Direct ✅ Versioned ✅ Logged ✅
