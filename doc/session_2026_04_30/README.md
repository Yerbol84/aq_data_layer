# AQ Data Layer — Руководство по использованию

> Состояние: **работает** (подтверждено Docker-запуском, 2026-04-30)

---

## Что это

`aq_data_layer` (`dart_vault`) — типизированный data layer для Dart/Flutter приложений.  
Поддерживает три режима хранения, работает локально (InMemory) и удалённо (PostgreSQL через RPC).

---

## Три режима хранения

| Режим | Когда использовать | Удаление | История |
|---|---|---|---|
| **Direct** | Настройки, проекты, простые сущности | Soft (deletedAt) | Нет |
| **Versioned** | Графы, схемы, конфиги с версиями | Soft (state=deleted) | Все версии навсегда |
| **Logged** | Сессии, запуски, аудируемые операции | Soft (deletedAt) + лог | Полный diff-лог |

---

## Быстрый старт

### Режим 1: Serverless (InMemory, без сервера)

```dart
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

final vault = Vault(
  storage: InMemoryVaultStorage(tenantId: 'user-1'),
  tenantId: 'user-1',
);

final projects = vault.direct<AqStudioProject>(
  collection: AqStudioProject.kCollection,
  fromMap: AqStudioProject.fromMap,
);

await projects.save(project);
final found = await projects.findById('proj-1');
```

Подходит для: desktop-приложения, тесты, прототипы.

### Режим 2: Client-Server (PostgreSQL через RPC)

**Клиент** (Flutter / Dart CLI):

```dart
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

// Один раз при старте приложения
await IDataLayer.initialize(
  endpoint: 'http://localhost:8765',
  tenantId: 'user-1',       // опционально, по умолчанию 'system'
  useBuffer: true,           // offline-first буфер
);

// Везде в приложении
final projects = IDataLayer.instance.direct<AqStudioProject>(
  collection: AqStudioProject.kCollection,
  fromMap: AqStudioProject.fromMap,
);
```

**Сервер** (отдельный процесс):

```dart
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

final registry = VaultRegistry(
  storageFactory: (tenantId) => PostgresVaultStorage(pool: pool, tenantId: tenantId),
  deployer: PostgresSchemaDeployer(pool: pool),
);

// Регистрируем домены из aq_schema (единый источник правды)
for (final domain in AqDomains.all) {
  registry.register(DomainRegistration(
    collection: domain.collection,
    mode: _toStorageMode(domain.kind),
    fromMap: domain.fromMap,
    indexes: domain.indexes,
    jsonSchema: const {'type': 'object'},
  ));
}

await registry.deploy(); // создаёт таблицы автоматически
```

---

## Direct Repository

```dart
final repo = IDataLayer.instance.direct<AqStudioProject>(
  collection: AqStudioProject.kCollection,
  fromMap: AqStudioProject.fromMap,
);

// CRUD
await repo.save(project);
final item = await repo.findById('id');
final all  = await repo.findAll();
final page = await repo.findPage(VaultQuery(limit: 20, offset: 0));
await repo.delete('id');                    // soft delete (deletedAt)

// Фильтрация
final filtered = await repo.findAll(
  query: VaultQuery().where('projectType', VaultOperator.equals, 'workflow'),
);

// Включая удалённые
final withDeleted = await repo.findAllIncludingDeleted();

// Восстановить
await repo.restore('id');
```

---

## Versioned Repository

```dart
final repo = IDataLayer.instance.versioned<WorkflowGraph>(
  collection: WorkflowGraph.kCollection,
  fromMap: WorkflowGraph.fromMap,
);

// Жизненный цикл версии
final node = await repo.createEntity(graph);          // draft
await repo.updateDraft(node.nodeId, updatedGraph);    // редактировать
final pub = await repo.publishDraft(                  // → published
  node.nodeId,
  increment: IncrementType.minor,                     // 0.0.0 → 0.1.0
);

// Ветки
final branch = await repo.createBranch(
  pub.nodeId,
  branchName: 'feature/new-step',
  model: graph,
);

// Навигация
final current  = await repo.getCurrent(graph.id);
final latest   = await repo.getLatestPublished(graph.id);
final versions = await repo.listVersions(graph.id);

// Доступ
await repo.grantAccess(graph.id, actorId: 'user-2', level: AccessLevel.read, requesterId: 'me');
await repo.revokeAccess(graph.id, actorId: 'user-2', requesterId: 'me');
final grants = await repo.listGrants(graph.id);

// Удаление (soft)
await repo.deleteEntity(graph.id);
```

---

## Logged Repository

```dart
final repo = IDataLayer.instance.logged<WorkflowRun>(
  collection: WorkflowRun.kCollection,
  fromMap: WorkflowRun.fromMap,
);

// Каждый save() автоматически пишет diff в лог
await repo.save(run, actorId: 'user-1');
await repo.save(updatedRun, actorId: 'user-1');

// Аудит
final history = await repo.getHistory(run.id);
// history[i].operation, .changedBy, .changedAt, .diff

// Откат к предыдущему состоянию
await repo.rollbackTo(run.id, history.first.entryId, actorId: 'user-1');

// Удаление (лог сохраняется навсегда)
await repo.delete(run.id, actorId: 'user-1');
```

---

## Мультитенантность

Изоляция встроена: каждый запрос содержит `tenantId`, SQL фильтрует по нему автоматически.

```dart
// Tenant A
await IDataLayer.initialize(endpoint: '...', tenantId: 'company-a');
// Tenant B видит только свои данные
await IDataLayer.initialize(endpoint: '...', tenantId: 'company-b');
```

В serverless режиме — отдельный `Vault` на каждый tenant.

---

## Домены из aq_schema

Готовые домены (не нужно создавать свои для платформы):

| Домен | Режим | Collection |
|---|---|---|
| `AqStudioProject` | Direct | `projects` |
| `WorkflowGraph` | Versioned | `workflow_graphs` |
| `WorkflowRun` | Logged | `workflow_runs` |
| `GraphRunState` | Direct | `graph_run_states` |
| `TestDocumentV1` | Direct | `test_documents` |

Все домены зарегистрированы в `AqDomains.all` — сервер регистрирует их одним циклом.

---

## Запуск Docker стека

```bash
cd example/stack
docker compose up --build -d

# Запустить все сценарии
docker compose run --rm scenarios

# Запустить клиент
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  stack-scenarios
```

---

## Добавить свой домен

1. Создать класс в `aq_schema`, реализующий `DirectStorable` / `VersionedStorable` / `LoggedStorable`
2. Добавить в `AqDomains.all`
3. Сервер подхватит автоматически при следующем деплое

```dart
class MyEntity implements DirectStorable {
  @override final String id;
  @override String get collectionName => kCollection;
  @override Map<String, dynamic> toMap() => {'id': id, ...};
  @override Map<String, dynamic> get indexFields => {'name': name};
  @override Map<String, dynamic> get jsonSchema => kJsonSchema;
  @override bool get softDelete => true;

  static const kCollection = 'my_entities';
  factory MyEntity.fromMap(Map<String, dynamic> m) => MyEntity(id: m['id']);
}
```
