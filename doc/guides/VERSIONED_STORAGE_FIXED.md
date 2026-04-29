# Исправление RPC протокола для Versioned Storage

**Дата:** 2026-04-11
**Статус:** ✅ ИСПРАВЛЕНО
**Версия:** 0.4.1

---

## 🎯 Что было исправлено

### Проблема

Клиент отправлял `VersionNode` вместо модели графа, что вызывало ошибку десериализации на сервере.

### Исправления

#### 1. `createEntity` — строка 103

**Было:**
```dart
await _storage.put(_collection, nodeId, node.toMap());
```

**Стало:**
```dart
// ВАЖНО: Отправляем модель, а не VersionNode! Сервер создаст VersionNode сам.
await _storage.put(_collection, nodeId, model.toMap());
```

**Результат:** Сервер получает модель графа и создаёт VersionNode самостоятельно.

---

#### 2. `updateDraft` — строка 186-188

**Было:**
```dart
if (baseStorage is ProxyStorage) {
  await _storage.put(_collection, nodeId, updated.toMap());
}
```

**Стало:**
```dart
if (baseStorage is ProxyStorage) {
  // Remote: используем специальную операцию updateDraft
  // Отправляем модель, а не VersionNode!
  await baseStorage.put(_collection, nodeId, {
    'operation': 'updateDraft',
    'nodeId': nodeId,
    'data': model.toMap(),
  });
}
```

**Результат:** Используется механизм специальных операций, сервер получает модель графа.

---

## 📋 RPC Протокол (после исправления)

### Operation: put (createEntity)

**Клиент отправляет:**
```dart
await workflows.createEntity(workflow);
```

**RPC запрос:**
```json
{
  "collection": "workflow_graphs",
  "operation": "put",
  "tenantId": "user-123",
  "args": {
    "id": "node_abc123",
    "data": {
      "id": "wf-1",
      "name": "My Workflow",
      "nodes": [...],
      "edges": [...]
    }
  }
}
```

**Сервер обрабатывает:**
```dart
final model = WorkflowGraph.fromMap(args['data']);
final node = await repo.createEntity(model);
return node.toMap();
```

**RPC ответ:**
```json
{
  "result": {
    "nodeId": "node_abc123",
    "entityId": "wf-1",
    "status": "draft",
    "data": "{\"id\":\"wf-1\",...}",
    "createdAt": "2026-04-11T10:00:00Z",
    ...
  }
}
```

---

### Operation: updateDraft

**Клиент отправляет:**
```dart
await workflows.updateDraft(nodeId, updatedWorkflow);
```

**RPC запрос:**
```json
{
  "collection": "workflow_graphs",
  "operation": "updateDraft",
  "tenantId": "user-123",
  "args": {
    "nodeId": "node_abc123",
    "data": {
      "id": "wf-1",
      "name": "Updated Workflow",
      "nodes": [...],
      "edges": [...]
    }
  }
}
```

**Сервер обрабатывает:**
```dart
final model = WorkflowGraph.fromMap(args['data']);
await repo.updateDraft(args['nodeId'], model);
```

---

### Operation: publishDraft

**Клиент отправляет:**
```dart
await workflows.publishDraft(nodeId, increment: IncrementType.minor);
```

**RPC запрос:**
```json
{
  "collection": "workflow_graphs",
  "operation": "publishDraft",
  "tenantId": "user-123",
  "args": {
    "nodeId": "node_abc123",
    "increment": "minor"
  }
}
```

**Сервер обрабатывает:**
```dart
final node = await repo.publishDraft(
  args['nodeId'],
  increment: IncrementType.minor,
);
return node.toMap();
```

---

## 🚀 Как использовать (примеры)

### 1. Создание нового графа

```dart
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

// Подключиться к Data Service
await Vault.connect('http://localhost:8765', tenantId: 'user-123');

// Получить репозиторий
final workflows = Vault.instance.versioned<WorkflowGraph>(
  collection: WorkflowGraph.kCollection,
  fromMap: WorkflowGraph.fromMap,
);

// Создать новый граф (draft)
final workflow = WorkflowGraph(
  id: 'wf-${DateTime.now().millisecondsSinceEpoch}',
  name: 'My First Workflow',
  ownerId: 'user-123',
  nodes: [
    WorkflowNode(
      id: 'node-1',
      type: 'start',
      data: {'label': 'Start'},
    ),
  ],
  edges: [],
  accessGrants: [],
);

final node = await workflows.createEntity(workflow);
print('Created: ${node.nodeId}, status: ${node.status}');
// Output: Created: node_abc123, status: draft
```

---

### 2. Обновление draft версии

```dart
// Получить текущий draft
final nodes = await workflows.findNodes(
  entityId: workflow.id,
  status: VersionStatus.draft,
);
final draftNode = nodes.first;

// Обновить граф
final updatedWorkflow = workflow.copyWith(
  name: 'Updated Workflow Name',
  nodes: [
    ...workflow.nodes,
    WorkflowNode(
      id: 'node-2',
      type: 'action',
      data: {'label': 'Process'},
    ),
  ],
);

await workflows.updateDraft(draftNode.nodeId, updatedWorkflow);
print('Draft updated');
```

---

### 3. Публикация draft → published

```dart
// Опубликовать draft с версией
final published = await workflows.publishDraft(
  draftNode.nodeId,
  increment: IncrementType.minor, // major | minor | patch
);

print('Published: ${published.version}'); // 1.1.0
print('Status: ${published.status}');     // published
```

---

### 4. Полный цикл: создание → редактирование → публикация

```dart
// 1. Создать draft
final workflow = WorkflowGraph(
  id: 'wf-demo',
  name: 'Demo Workflow',
  ownerId: 'user-123',
  nodes: [],
  edges: [],
  accessGrants: [],
);

final draft = await workflows.createEntity(workflow);
print('Step 1: Created draft ${draft.nodeId}');

// 2. Обновить draft несколько раз
for (int i = 1; i <= 3; i++) {
  final updated = workflow.copyWith(
    name: 'Demo Workflow v$i',
    nodes: List.generate(
      i,
      (index) => WorkflowNode(
        id: 'node-$index',
        type: 'action',
        data: {'step': index},
      ),
    ),
  );

  await workflows.updateDraft(draft.nodeId, updated);
  print('Step 2.$i: Updated draft');
}

// 3. Опубликовать
final published = await workflows.publishDraft(
  draft.nodeId,
  increment: IncrementType.major,
);
print('Step 3: Published v${published.version}');

// 4. Получить текущую версию
final current = await workflows.getCurrent(workflow.id);
print('Current version: ${current.version}');
```

---

### 5. Работа с ветками

```dart
// Создать ветку для экспериментов
final featureBranch = await workflows.createBranch(
  published.nodeId,
  branchName: 'feature-new-nodes',
  model: workflow.copyWith(
    name: 'Experimental Workflow',
  ),
);

print('Created branch: ${featureBranch.branch}');

// Работать в ветке
await workflows.updateDraft(
  featureBranch.nodeId,
  workflow.copyWith(
    nodes: [
      WorkflowNode(id: 'experimental-node', type: 'test', data: {}),
    ],
  ),
);

// Слить ветку обратно в main
final merged = await workflows.mergeToMain(
  workflow.id,
  sourceBranch: 'feature-new-nodes',
  requesterId: 'user-123',
  fromMap: WorkflowGraph.fromMap,
);

print('Merged to main: ${merged.nodeId}');
```

---

### 6. История версий

```dart
// Получить все версии
final versions = await workflows.listVersions(workflow.id);

print('Version history:');
for (final v in versions) {
  print('  ${v.version ?? 'draft'} - ${v.status} - ${v.createdAt}');
}

// Output:
// Version history:
//   draft - draft - 2026-04-11T10:00:00Z
//   1.0.0 - published - 2026-04-11T10:05:00Z
//   1.1.0 - published - 2026-04-11T10:10:00Z
```

---

### 7. Получение конкретной версии

```dart
// Получить текущую опубликованную версию
final current = await workflows.getCurrent(workflow.id);
print('Current: ${current.version}');

// Получить конкретную версию по nodeId
final specific = await workflows.getVersion(someNodeId);
print('Specific: ${specific.version}');

// Получить данные графа из VersionNode
final graph = WorkflowGraph.fromMap(current.data);
print('Graph name: ${graph.name}');
print('Nodes count: ${graph.nodes.length}');
```

---

## 🧪 Тестирование

### Запуск тестов

```bash
# Запустить PostgreSQL
docker-compose up -d

# Запустить все тесты
dart test

# Только интеграционные тесты versioned storage
dart test test/integration/versioned_storage_test.dart
```

### Пример теста

```dart
test('createEntity → updateDraft → publishDraft', () async {
  final workflow = WorkflowGraph(
    id: 'test-wf',
    name: 'Test Workflow',
    ownerId: 'test-user',
    nodes: [],
    edges: [],
    accessGrants: [],
  );

  // Создать draft
  final draft = await workflows.createEntity(workflow);
  expect(draft.status, VersionStatus.draft);
  expect(draft.version, isNull);

  // Обновить draft
  final updated = workflow.copyWith(name: 'Updated Workflow');
  await workflows.updateDraft(draft.nodeId, updated);

  // Опубликовать
  final published = await workflows.publishDraft(
    draft.nodeId,
    increment: IncrementType.major,
  );
  expect(published.status, VersionStatus.published);
  expect(published.version.toString(), '1.0.0');

  // Проверить что данные сохранились
  final graph = WorkflowGraph.fromMap(published.data);
  expect(graph.name, 'Updated Workflow');
});
```

---

## ✅ Критерии успеха

После исправления:
- ✅ Клиент отправляет модель графа, а не VersionNode
- ✅ Сервер успешно десериализует модель
- ✅ `createEntity` работает корректно
- ✅ `updateDraft` работает корректно
- ✅ `publishDraft` работает корректно (уже работал)
- ✅ Интеграционные тесты проходят
- ✅ Нет ошибок "type 'Null' is not a subtype of type 'String'"

---

## 📚 Связанные документы

- [RPC_PROTOCOL_BUG_ANALYSIS.md](RPC_PROTOCOL_BUG_ANALYSIS.md) — детальный анализ проблемы
- [ARCHITECTURE.md](ARCHITECTURE.md) — архитектура системы
- [KEY_DECISIONS.md](KEY_DECISIONS.md) — ключевые архитектурные решения
- [../guides/USAGE_GUIDE.md](../guides/USAGE_GUIDE.md) — полное руководство пользователя

---

## 🔄 Changelog

### v0.4.1 (2026-04-11)

**Fixed:**
- 🐛 RPC протокол для `createEntity` — клиент теперь отправляет модель вместо VersionNode
- 🐛 RPC протокол для `updateDraft` — используется механизм специальных операций
- 📝 Добавлены комментарии в код для ясности

**Improved:**
- 📖 Документация RPC протокола
- 📖 Примеры использования versioned storage
- 📖 Руководство по тестированию
