# RLS Implementation TODO

**Статус:** Частично завершено (30%)
**Дата:** 2026-04-09

## ✅ Завершено

1. **PostgresSchemaDeployer:**
   - ✅ Метод `_enableRls()` создан
   - ✅ Вызовы `_enableRls()` добавлены в:
     - `_createDirectTable()` → включает RLS на основной таблице
     - `_createVersionedTables()` → включает RLS на `_versions` и `_current`
     - `_createLoggedTables()` → включает RLS на основной и `_log` таблицах

2. **PostgresVaultStorage:**
   - ✅ Метод `_setTenantContext()` создан

## ⚠️ Требуется завершить

### PostgresVaultStorage - обновить все методы

Каждый метод нужно обернуть в `connection.runTx()` с установкой контекста и убрать явные `WHERE tenant_id`.

#### Шаблон для обновления:

**БЫЛО:**
```dart
@override
Future<void> put(String collection, String id, Map<String, dynamic> data) async {
  await connection.execute(
    '''INSERT INTO $collection (id, tenant_id, data, created_at, updated_at)
       VALUES (\$1, \$2, \$3, NOW(), NOW())
       ON CONFLICT (id, tenant_id)
       DO UPDATE SET data = EXCLUDED.data, updated_at = NOW()''',
    parameters: [id, tenantId, data],
  );
}
```

**СТАЛО:**
```dart
@override
Future<void> put(String collection, String id, Map<String, dynamic> data) async {
  await connection.runTx((session) async {
    await _setTenantContext(session);
    await session.execute(
      '''INSERT INTO $collection (id, tenant_id, data, created_at, updated_at)
         VALUES (\$1, \$2, \$3, NOW(), NOW())
         ON CONFLICT (id, tenant_id)
         DO UPDATE SET data = EXCLUDED.data, updated_at = NOW()''',
      parameters: [id, tenantId, data],
    );
  });
}
```

#### Методы требующие обновления:

1. **put()** - строка 54
2. **get()** - строка 71
   - Убрать `WHERE id = \$1 AND tenant_id = \$2`
   - Заменить на `WHERE id = \$1` (RLS добавит tenant_id автоматически)
   - Убрать `tenantId` из parameters

3. **delete()** - строка 82
   - Убрать `WHERE id = \$1 AND tenant_id = \$2`
   - Заменить на `WHERE id = \$1`

4. **exists()** - строка 92
   - Убрать `WHERE id = \$1 AND tenant_id = \$2`
   - Заменить на `WHERE id = \$1`

5. **putAll()** - строка ~100
   - Обернуть в `runTx`
   - Один `_setTenantContext()` для всего batch

6. **query()** - строка ~200
   - Обновить `_buildQuerySql()`:
     - Убрать `WHERE tenant_id = \$1`
     - Начинать с `WHERE 1=1`
   - Обновить `_buildQueryParams()`:
     - Убрать `tenantId` из параметров
     - Параметры начинаются с `\$1` (не `\$2`)

7. **queryPage()** - строка ~250
   - Аналогично `query()`

8. **count()** - строка ~280
   - Обновить `_buildCountSql()`:
     - Убрать `WHERE tenant_id = \$1`
     - Начинать с `WHERE 1=1`

9. **clear()** - строка ~220
   - Убрать `WHERE tenant_id = \$1`
   - RLS автоматически ограничит удаление текущим tenant

10. **transaction()** - строка ~300
    - Установить контекст в начале транзакции
    - Все операции внутри будут использовать этот контекст

### PostgresVersionedRepository - аналогичные изменения

Файл: `lib/storage/postgres/postgres_versioned_repository.dart`

Все SQL запросы с `WHERE tenant_id = @tenant` нужно обновить:
- Убрать явный `WHERE tenant_id = @tenant`
- Обернуть в `_connection.runTx()` с `_setTenantContext()`
- Убрать `tenant_id` из параметров

Методы:
- `createEntity()`
- `updateDraft()`
- `publishDraft()`
- `getCurrent()`
- `getVersion()`
- `listVersions()`
- `deleteVersion()`
- `deleteEntity()`
- `grantAccess()`
- `revokeAccess()`
- `hasAccess()`
- `createBranch()`
- `mergeToMain()`

### Пример для query методов

**_buildQuerySql() - БЫЛО:**
```dart
String _buildQuerySql(String collection, VaultQuery query) {
  final sql = StringBuffer('SELECT data FROM $collection WHERE tenant_id = \$1');
  for (var i = 0; i < query.filters.length; i++) {
    final paramIndex = i + 2; // +2 потому что $1 = tenant_id
    sql.write(' AND ${_buildFilterClause(query.filters[i], paramIndex)}');
  }
  // ... сортировка и пагинация
  return sql.toString();
}
```

**_buildQuerySql() - СТАЛО:**
```dart
String _buildQuerySql(String collection, VaultQuery query) {
  // tenant_id фильтр добавляется автоматически через RLS
  final sql = StringBuffer('SELECT data FROM $collection WHERE 1=1');
  for (var i = 0; i < query.filters.length; i++) {
    final paramIndex = i + 1; // $1 теперь первый фильтр
    sql.write(' AND ${_buildFilterClause(query.filters[i], paramIndex)}');
  }
  // ... сортировка и пагинация
  return sql.toString();
}
```

**_buildQueryParams() - БЫЛО:**
```dart
List<dynamic> _buildQueryParams(VaultQuery query) {
  return [tenantId, ...query.filters.map((f) => f.value)];
}
```

**_buildQueryParams() - СТАЛО:**
```dart
List<dynamic> _buildQueryParams(VaultQuery query) {
  // tenant_id больше не нужен — убрать из параметров
  return query.filters.map((f) => f.value).toList();
}
```

## 🧪 Тестирование после завершения

1. Запустить `dart analyze` - должно быть 0 ошибок
2. Запустить unit тесты: `dart test`
3. Запустить integration тесты с PostgreSQL:
   ```bash
   export TEST_PG_URL="postgresql://user:pass@localhost:5432/test_db"
   dart test test/postgres/
   ```

## 📝 Проверочный список

- [ ] Все методы в `PostgresVaultStorage` обёрнуты в `runTx`
- [ ] Все `WHERE tenant_id = \$X` заменены на RLS
- [ ] Все `_buildQuerySql()` начинаются с `WHERE 1=1`
- [ ] Все `_buildQueryParams()` не содержат `tenantId`
- [ ] `PostgresVersionedRepository` обновлён аналогично
- [ ] `dart analyze` проходит без ошибок
- [ ] Unit тесты проходят
- [ ] Integration тесты с PostgreSQL проходят

## ⏱️ Оценка времени

- PostgresVaultStorage: ~2 часа (10 методов)
- PostgresVersionedRepository: ~2 часа (12 методов)
- Тестирование и исправление: ~1 час
- **Итого:** ~5 часов

## 🎯 Приоритет

**ВЫСОКИЙ** - без этого RLS не работает, tenant-изоляция не гарантирована.
