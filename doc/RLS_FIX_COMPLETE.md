# ✅ Исправление RLS (Row Level Security) — Полный отчёт

**Дата:** 2026-04-11
**Статус:** ✅ ИСПРАВЛЕНО И ПРОТЕСТИРОВАНО

---

## 🐛 Проблема

При работе с `PostgresVersionedRepository` операции `updateDraft` и `publishDraft` не работали из-за **Row Level Security (RLS)** политик PostgreSQL.

### Симптомы

1. **updateDraft** выполнялся успешно (HTTP 200), но данные в базе НЕ обновлялись
2. **publishDraft** падал с ошибкой `VaultNotFoundException: Node not found`

### Причина

RLS политика требует установки `current_setting('app.current_tenant')` перед любыми операциями с данными:

```sql
CREATE POLICY workflow_graphs_versions_tenant_isolation ON workflow_graphs_versions
  FOR ALL USING (tenant_id = current_setting('app.current_tenant', true));
```

Методы `updateDraft` и `publishDraft` выполняли SQL запросы напрямую через `_connection.execute()`, **не устанавливая tenant context**. Из-за этого:
- UPDATE в `updateDraft` не находил строки (RLS блокировал доступ)
- SELECT в `publishDraft` не находил node (RLS блокировал чтение)

---

## ✅ Решение

### 1. Исправление `updateDraft`

**Было:**
```dart
Future<void> updateDraft(String nodeId, T model) async {
  await _connection.execute(
    'UPDATE $_versionsTable SET data = $1 WHERE node_id = $2 AND tenant_id = $3',
    parameters: [model.toMap(), nodeId, _tenantId],
  );
}
```

**Стало:**
```dart
Future<void> updateDraft(String nodeId, T model) async {
  await _connection.runTx((session) async {
    await _setTenantContext(session);  // ✅ Устанавливаем tenant context
    await session.execute(
      'UPDATE $_versionsTable SET data = $1 WHERE node_id = $2 AND tenant_id = $3',
      parameters: [model.toMap(), nodeId, _tenantId],
    );
  });
}
```

### 2. Исправление `publishDraft`

**Было:**
```dart
Future<VersionNode> publishDraft(String nodeId, {required IncrementType increment}) async {
  final node = await _getNodeById(nodeId);  // ❌ Без tenant context
  // ... UPDATE без tenant context
  // ... _setCurrentVersion без tenant context
}
```

**Стало:**
```dart
Future<VersionNode> publishDraft(String nodeId, {required IncrementType increment}) async {
  return await _connection.runTx((session) async {
    await _setTenantContext(session);  // ✅ Устанавливаем tenant context

    final node = await _getNodeByIdInSession(session, nodeId);
    // ... все операции через session с установленным контекстом
  });
}
```

### 3. Добавлены вспомогательные методы

Для работы внутри транзакций добавлены методы, принимающие `TxSession`:

```dart
Future<VersionNode?> _getNodeByIdInSession(TxSession session, String nodeId)
Future<void> _setCurrentVersionInSession(TxSession session, String entityId, String nodeId)
Future<Semver?> _getLatestVersionInSession(TxSession session, String entityId)
```

---

## 🧪 Тестирование

### Полный цикл работы с версионированием

```bash
# 1. Создание draft
curl -X POST http://localhost:8765/vault/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "collection": "workflow_graphs",
    "operation": "put",
    "tenantId": "test-user",
    "args": {
      "data": {
        "id": "wf-final-test",
        "name": "Final Test Workflow",
        "nodes": [],
        "edges": [],
        "ownerId": "test-user",
        "accessGrants": []
      }
    }
  }'

# Результат: ✅ Created nodeId: node_1775889176168_974084217

# 2. Обновление draft
curl -X POST http://localhost:8765/vault/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "collection": "workflow_graphs",
    "operation": "updateDraft",
    "tenantId": "test-user",
    "args": {
      "nodeId": "node_1775889176168_974084217",
      "data": {
        "id": "wf-final-test",
        "name": "UPDATED: Final Test Workflow",
        "nodes": [],
        "edges": [],
        "ownerId": "test-user",
        "accessGrants": []
      }
    }
  }'

# Результат: ✅ {"success": true, "data": null}
# Проверка в БД: ✅ Данные обновились!

# 3. Публикация draft
curl -X POST http://localhost:8765/vault/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "collection": "workflow_graphs",
    "operation": "publishDraft",
    "tenantId": "test-user",
    "args": {
      "nodeId": "node_1775889176168_974084217",
      "increment": "major"
    }
  }'

# Результат: ✅ Published version 1.0.0 с актуальными данными!
```

### Результаты тестирования

```json
{
  "success": true,
  "data": {
    "nodeId": "node_1775889176168_974084217",
    "entityId": "wf-final-test",
    "status": "published",
    "version": "1.0.0",
    "data": "{\"name\":\"UPDATED: Final Test Workflow\", ...}",
    "isCurrent": true
  }
}
```

✅ Все три операции работают корректно!

---

## 📝 Изменённые файлы

### 1. `lib/storage/postgres/postgres_versioned_repository.dart`

**Изменения:**
- Метод `updateDraft` (строки 161-174): обёрнут в `runTx` с `_setTenantContext`
- Метод `publishDraft` (строки 182-228): полностью переписан для работы в транзакции
- Добавлены методы `_getNodeByIdInSession`, `_setCurrentVersionInSession`, `_getLatestVersionInSession` (строки 677-750)

### 2. `lib/storage/versioned_repository_impl.dart`

**Изменения:**
- Метод `updateDraft` (строки 186-198): изменён с `baseStorage.put()` на прямой RPC вызов через `(baseStorage as dynamic).rpc()`

---

## 🔍 Связанные исправления

Эта проблема была обнаружена после исправления основных RPC багов:

1. ✅ **Проблема #1**: Клиент отправлял `VersionNode.toMap()` вместо `model.toMap()` в `createEntity`
2. ✅ **Проблема #2**: PostgreSQL JSONB десериализация без проверки типов
3. ✅ **Проблема #3**: `publishDraft` не перечитывал данные после UPDATE
4. ✅ **Проблема #4**: `_getNodeOrThrow` не работал с remote storage
5. ✅ **Проблема #5 (RLS)**: `updateDraft` и `publishDraft` не устанавливали tenant context

---

## 📚 Документация

- **Полное руководство:** `doc/guides/VERSIONED_STORAGE_FIXED.md`
- **Анализ RPC проблем:** `doc/architecture/RPC_PROTOCOL_BUG_ANALYSIS.md`
- **Краткая сводка:** `RPC_FIX_SUMMARY.md`
- **Отчёт о пересборке:** `deploys/aq_studio_dl_stack/REBUILD_REPORT.md`

---

## 🎯 Итог

Все критические проблемы с RPC протоколом и RLS исправлены:

- ✅ `createEntity` отправляет модель, а не VersionNode
- ✅ PostgreSQL JSONB корректно десериализуется
- ✅ `publishDraft` возвращает актуальные данные
- ✅ `_getNodeOrThrow` работает с remote storage
- ✅ `updateDraft` устанавливает tenant context и обновляет данные
- ✅ `publishDraft` устанавливает tenant context и публикует версии

Система готова к использованию! 🚀
