# 🎉 Исправление RPC протокола — Краткая сводка

**Дата:** 2026-04-11
**Статус:** ✅ ИСПРАВЛЕНО

---

## Что было исправлено

### Проблема
Клиент отправлял `VersionNode.toMap()` вместо модели графа → сервер не мог десериализовать → ошибка.

### Решение
Изменены 2 строки в `lib/storage/versioned_repository_impl.dart`:

1. **Строка 103** (`createEntity`):
   ```dart
   // Было: await _storage.put(_collection, nodeId, node.toMap());
   await _storage.put(_collection, nodeId, model.toMap());  // ✅
   ```

2. **Строки 186-192** (`updateDraft`):
   ```dart
   // Было: await _storage.put(_collection, nodeId, updated.toMap());
   await baseStorage.put(_collection, nodeId, {
     'operation': 'updateDraft',
     'nodeId': nodeId,
     'data': model.toMap(),  // ✅
   });
   ```

---

## Как использовать

```dart
// 1. Подключиться
await Vault.connect('http://localhost:8765', tenantId: 'user-123');

// 2. Получить репозиторий
final workflows = Vault.instance.versioned<WorkflowGraph>(
  collection: WorkflowGraph.kCollection,
  fromMap: WorkflowGraph.fromMap,
);

// 3. Создать граф (draft)
final workflow = WorkflowGraph(
  id: 'wf-1',
  name: 'My Workflow',
  ownerId: 'user-123',
  nodes: [],
  edges: [],
  accessGrants: [],
);

final draft = await workflows.createEntity(workflow);  // ✅ Работает!

// 4. Обновить draft
final updated = workflow.copyWith(name: 'Updated');
await workflows.updateDraft(draft.nodeId, updated);  // ✅ Работает!

// 5. Опубликовать
final published = await workflows.publishDraft(
  draft.nodeId,
  increment: IncrementType.major,
);
print('Published: ${published.version}');  // 1.0.0
```

---

## Тестирование

```bash
# Запустить PostgreSQL
docker-compose up -d

# Запустить тесты
dart test
```

---

## Документация

- **Полное руководство:** `doc/guides/VERSIONED_STORAGE_FIXED.md`
- **Анализ проблемы:** `doc/architecture/RPC_PROTOCOL_BUG_ANALYSIS.md`
- **Архитектура:** `doc/architecture/ARCHITECTURE.md`

---

## Что дальше?

1. ✅ Исправление применено
2. ⏳ Запустить тесты для проверки
3. ⏳ Обновить версию пакета до 0.4.1
4. ⏳ Создать CHANGELOG.md запись

Всё готово к использованию! 🚀
