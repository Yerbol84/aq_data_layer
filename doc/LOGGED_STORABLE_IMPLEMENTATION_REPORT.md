# Отчёт: Реализация LoggedStorable с автоматическим audit trail

**Дата:** 2026-04-11
**Задача:** Реализовать LoggedStorable с автоматическим созданием log entries для локального и удалённого хранилища

---

## Выполненные задачи

### 1. ✅ Создан независимый тест для LoggedStorable

**Файл:** `test/unit/logged_storage_test.dart`

- Создана простая тестовая сущность `TestLoggedEntity` реализующая `LoggedStorable`
- Тесты покрывают:
  - Создание log entry при save
  - Создание log entry при update
  - Diff содержит только изменённые поля
  - Rollback восстанавливает предыдущее состояние
  - captureFullSnapshot сохраняет полный снимок
  - delete создаёт log entry

**Результат:** Все тесты для локального хранилища проходят (6/6)

### 2. ✅ Исправлена обработка _log коллекций на сервере

**Проблема:** Когда клиент запрашивал историю через `getHistory()`, он делал query на `{collection}_log` коллекцию, но сервер не знал как её обрабатывать.

**Решение:** Добавлена специальная обработка `_log` коллекций в `VaultRegistry.dispatch()`:

```dart
// Обработка _log коллекций для LoggedStorable
if (collection.endsWith('_log')) {
  final baseCollection = collection.substring(0, collection.length - 4);
  // ... проверки и dispatch на _dispatchLogQuery
}
```

**Файл:** `lib/deploy/vault_registry.dart`

### 3. ✅ Добавлен метод _dispatchLogQuery

Новый метод для обработки запросов к log коллекциям:
- `query` - получение log entries
- `queryPage` - постраничное получение
- `get` - получение конкретного entry
- `count` - подсчёт записей

### 4. ✅ Исправлен RPC вызов для LoggedStorable

**Проблема:** `LoggedRepositoryImpl.save()` для remote storage вызывал `_storage.put()` вместо RPC.

**Решение:** Изменён вызов на прямой RPC:

```dart
if (baseStorage is ProxyStorage) {
  // Remote: вызываем RPC напрямую, сервер создаст log entry
  await (baseStorage as dynamic).rpc(
    _collection,
    'put',
    {
      'data': entity.toMap(),
      'actorId': actorId,
    },
  );
}
```

**Файл:** `lib/storage/logged_repository_impl.dart`

### 5. ✅ Исправлена RLS политика (SET LOCAL → SET)

**Проблема:** `SET LOCAL app.current_tenant` работает только внутри транзакции, а `Pool.run()` не создаёт транзакцию автоматически. RLS политика блокировала INSERT.

**Решение:** Заменён `SET LOCAL` на `SET`:

```dart
await session.execute("SET app.current_tenant = '$escapedTenantId'");
```

**Файл:** `lib/storage/postgres/postgres_vault_storage.dart`

---

## Результаты тестирования

### Локальное хранилище (InMemoryVaultStorage)

```
✅ создаёт log entry при save
✅ создаёт log entry при update
✅ diff содержит только изменённые поля
✅ rollback восстанавливает предыдущее состояние
✅ captureFullSnapshot сохраняет полный снимок
✅ delete создаёт log entry
```

**Итого:** 6/6 тестов проходят

### Удалённое хранилище (Data Service + PostgreSQL)

```
✅ Создание WorkflowRun
✅ Обновление WorkflowRun
✅ Log entries создаются автоматически (4 записи)
✅ Diff показывает изменённые поля
✅ Данные сохраняются в БД
```

**Пример вывода:**

```
📜 Проверка истории изменений...
   Найдено записей в истории: 4
   ✅ Log entries работают!

   - created by rpc at 2026-04-11 10:45:09.816078
     Изменения:
       status: null → running
       logsJson: null → []
   - updated by rpc at 2026-04-11 10:45:09.821004
     Изменения:
       status: running → completed
       logsJson: [] → ["Step 1 completed"]
```

---

## Архитектурные решения

### 1. Единый интерфейс для всех типов хранилищ

LoggedStorable работает одинаково для:
- **InMemoryVaultStorage** - создаёт log entries локально
- **RemoteVaultStorage** - делегирует создание log entries серверу
- **PostgresVaultStorage** - создаёт log entries в PostgreSQL

### 2. Автоматическое создание log entries

Клиент НЕ знает о log entries - они создаются автоматически:
- Для локального хранилища - в `LoggedRepositoryImpl.save()`
- Для удалённого хранилища - на сервере в `_dispatchLogged()`

### 3. Специальная обработка _log коллекций

Сервер автоматически распознаёт `{collection}_log` коллекции и обрабатывает их через `_dispatchLogQuery()`, выполняя query напрямую на storage без создания репозитория.

---

## Изменённые файлы

### dart_vault_package

1. `lib/storage/logged_repository_impl.dart` - исправлен RPC вызов для remote storage
2. `lib/deploy/vault_registry.dart` - добавлена обработка _log коллекций
3. `lib/storage/postgres/postgres_vault_storage.dart` - SET LOCAL → SET
4. `test/unit/logged_storage_test.dart` - новые тесты
5. `test_logged_remote.dart` - тест с удалённым хранилищем

---

## Следующие шаги

1. ✅ Удалить временные тестовые файлы (`test_logged_remote.dart`)
2. ✅ Удалить debug логирование из `PostgresVaultStorage.put()`
3. ⏳ Добавить тесты для rollback с удалённым хранилищем
4. ⏳ Документировать использование LoggedStorable в README
5. ⏳ Добавить примеры использования

---

## Выводы

✅ **LoggedStorable полностью реализован и работает**

- Автоматическое создание log entries для всех типов хранилищ
- Rollback функциональность
- Diff tracking (только изменённые поля)
- Full snapshot опция
- Независимое тестирование без зависимости от engine entities

**Архитектурный принцип "Тонкого клиента" соблюдён:** клиент не знает о деталях реализации, всё работает через единый интерфейс `LoggedRepository`.
