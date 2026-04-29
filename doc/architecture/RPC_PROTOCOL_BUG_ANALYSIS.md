# Анализ проблемы RPC протокола для Versioned Storage

**Дата:** 2026-04-11
**Статус:** 🔴 Критическая проблема
**Компоненты:** dart_vault (client/server)

---

## 🐛 Описание проблемы

Существует **несоответствие протокола** между клиентом и сервером при работе с `VersionedRepository`:

### Что происходит

1. **Клиент** (`versioned_repository_impl.dart:103`):
   ```dart
   await _storage.put(_collection, nodeId, node.toMap());
   ```
   Отправляет **VersionNode** целиком

2. **VersionNode.toMap()** (`aq_schema/version_node.dart:59`):
   ```dart
   'data': jsonEncode(data),  // ← Данные графа кодируются в JSON-строку!
   ```

3. **Сервер получает** через RPC:
   ```json
   {
     "collection": "workflow_graphs",
     "operation": "put",
     "args": {
       "data": {
         "nodeId": "node_123",
         "entityId": "wf-1",
         "status": "draft",
         "data": "{\"id\":\"wf-1\",\"name\":\"My Graph\",...}",  ← JSON-строка!
         ...
       }
     }
   }
   ```

4. **Сервер пытается** (`vault_registry.dart:230`):
   ```dart
   final model = reg.fromMap(args['data'] as Map<String, dynamic>)
       as VersionedStorable;
   ```
   Десериализовать **VersionNode** как **WorkflowGraph** → **ОШИБКА!**

### Ошибка

```
type 'Null' is not a subtype of type 'String'
```

Потому что `WorkflowGraph.fromMap()` ожидает поля графа (`id`, `name`, `nodes`, `edges`), а получает поля VersionNode (`nodeId`, `entityId`, `status`, `data`).

---

## 🔍 Корневая причина

**Клиент и сервер имеют разные ожидания от операции `put`:**

| Компонент | Что отправляет/ожидает | Реальность |
|-----------|------------------------|------------|
| **Клиент** | Отправляет `VersionNode.toMap()` | ✅ Работает |
| **Сервер** | Ожидает `WorkflowGraph.toMap()` | ❌ Получает VersionNode |

**Проблема в строке 103** `versioned_repository_impl.dart`:
```dart
await _storage.put(_collection, nodeId, node.toMap());
```

Должно быть:
```dart
await _storage.put(_collection, nodeId, model.toMap());  // ← Отправить граф, не VersionNode
```

**НО!** Это создаст другую проблему — сервер не получит метаданные версии (nodeId, status, branch и т.д.).

---

## 💡 Варианты решения

### Вариант 1: Изменить клиент — отправлять только модель ✅ РЕКОМЕНДУЕТСЯ

**Суть:** Клиент отправляет `model.toMap()` вместо `node.toMap()`.

**Изменения:**

**1. В `versioned_repository_impl.dart:103`:**
```dart
// Было:
await _storage.put(_collection, nodeId, node.toMap());

// Стало:
await _storage.put(_collection, nodeId, model.toMap());
```

**2. Сервер создаёт VersionNode сам:**
```dart
// vault_registry.dart:229-233
case 'put': // createEntity
  final model = reg.fromMap(args['data'] as Map<String, dynamic>)
      as VersionedStorable;
  final node = await repo.createEntity(model);  // ← Сервер создаёт VersionNode
  return node.toMap();
```

**Преимущества:**
- ✅ Минимальные изменения
- ✅ Логично — клиент отправляет данные, сервер управляет версионированием
- ✅ Соответствует принципу "тонкого клиента"

**Недостатки:**
- ⚠️ Нужно проверить все операции (updateDraft, publishDraft и т.д.)

---

### Вариант 2: Изменить сервер — принимать VersionNode ❌ НЕ РЕКОМЕНДУЕТСЯ

**Суть:** Сервер извлекает модель из `args['data']['data']` и декодирует JSON.

**Изменения в `vault_registry.dart:229-233`:**
```dart
case 'put': // createEntity
  final versionNodeMap = args['data'] as Map<String, dynamic>;

  // Извлечь данные графа из VersionNode
  final dataJson = versionNodeMap['data'] as String;
  final modelMap = jsonDecode(dataJson) as Map<String, dynamic>;

  final model = reg.fromMap(modelMap) as VersionedStorable;
  final node = await repo.createEntity(model);
  return node.toMap();
```

**Преимущества:**
- ✅ Не меняет клиентский код

**Недостатки:**
- ❌ Сервер получает лишние данные (nodeId, status и т.д. от клиента)
- ❌ Клиент не должен генерировать nodeId — это задача сервера
- ❌ Нарушает принцип "тонкого клиента"
- ❌ Усложняет код сервера

---

### Вариант 3: Создать отдельную операцию RPC ❌ ИЗБЫТОЧНО

**Суть:** Разделить операции на `createEntity` (принимает модель) и `putVersionNode` (принимает VersionNode).

**Недостатки:**
- ❌ Избыточная сложность
- ❌ Дублирование логики
- ❌ Не решает проблему, а обходит её

---

### Вариант 4: Использовать специальный маркер в args ⚠️ КОМПРОМИСС

**Суть:** Клиент указывает тип данных в args.

**Изменения:**

**Клиент:**
```dart
await _storage.rpc(
  collection: _collection,
  operation: 'put',
  args: {
    'dataType': 'model',  // ← Маркер
    'data': model.toMap(),
  },
);
```

**Сервер:**
```dart
case 'put':
  final dataType = args['dataType'] as String? ?? 'model';

  if (dataType == 'versionNode') {
    // Обработка VersionNode (для обратной совместимости)
    final versionNodeMap = args['data'] as Map<String, dynamic>;
    final dataJson = versionNodeMap['data'] as String;
    final modelMap = jsonDecode(dataJson) as Map<String, dynamic>;
    final model = reg.fromMap(modelMap) as VersionedStorable;
  } else {
    // Обработка модели (новый способ)
    final model = reg.fromMap(args['data'] as Map<String, dynamic>)
        as VersionedStorable;
  }

  final node = await repo.createEntity(model);
  return node.toMap();
```

**Преимущества:**
- ✅ Обратная совместимость
- ✅ Явное указание типа данных

**Недостатки:**
- ⚠️ Усложняет протокол
- ⚠️ Требует изменений в обоих компонентах

---

## 🎯 Рекомендация

**Выбрать Вариант 1** — изменить клиент, отправлять `model.toMap()`.

### Почему?

1. **Соответствует архитектуре "тонкого клиента":**
   - Клиент отправляет данные
   - Сервер управляет версионированием (генерирует nodeId, status и т.д.)

2. **Минимальные изменения:**
   - Одна строка в клиенте
   - Сервер уже правильно написан

3. **Логично:**
   - `createEntity(model)` принимает модель, а не VersionNode
   - VersionNode — это результат операции, а не входные данные

4. **Безопасно:**
   - Клиент не может подделать nodeId или status
   - Сервер полностью контролирует версионирование

---

## 📋 План исправления

### Шаг 1: Исправить клиент

**Файл:** `lib/storage/versioned_repository_impl.dart`

**Строка 103:**
```dart
// Было:
await _storage.put(_collection, nodeId, node.toMap());

// Стало:
await _storage.put(_collection, nodeId, model.toMap());
```

### Шаг 2: Проверить другие операции

Убедиться что `updateDraft`, `publishDraft` и другие операции также отправляют модель, а не VersionNode.

**Проверить строки:**
- `updateDraft` — должен отправлять `model.toMap()`
- `publishDraft` — не отправляет данные, только nodeId
- `createBranch` — должен отправлять `model.toMap()`

### Шаг 3: Обновить тесты

Проверить что интеграционные тесты проходят после изменений.

### Шаг 4: Документировать протокол

Добавить в документацию явное описание RPC протокола для versioned операций:

```markdown
## RPC Protocol: Versioned Storage

### Operation: put (createEntity)

**Request:**
```json
{
  "collection": "workflow_graphs",
  "operation": "put",
  "args": {
    "data": {
      "id": "wf-1",
      "name": "My Graph",
      "nodes": [...],
      "edges": [...]
    }
  }
}
```

**Response:**
```json
{
  "result": {
    "nodeId": "node_123",
    "entityId": "wf-1",
    "status": "draft",
    "data": "{...}",
    ...
  }
}
```

**ВАЖНО:** `args['data']` содержит **модель графа**, а не VersionNode!
```

---

## 🔗 Связанные файлы

- `lib/storage/versioned_repository_impl.dart:103` — клиент отправляет VersionNode
- `lib/deploy/vault_registry.dart:229-233` — сервер ожидает модель
- `pkgs/aq_schema/lib/data_layer/models/version_node.dart:59` — toMap() кодирует data в JSON
- `doc/architecture/ARCHITECTURE.md` — описание RPC протокола

---

## ✅ Критерии успеха

После исправления:
- ✅ Клиент отправляет `model.toMap()` в операции `put`
- ✅ Сервер успешно десериализует модель
- ✅ Интеграционные тесты проходят
- ✅ Протокол задокументирован
- ✅ Нет регрессий в других операциях
