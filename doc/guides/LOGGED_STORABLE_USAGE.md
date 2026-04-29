# Использование LoggedStorable

LoggedStorable — это интерфейс для сущностей с автоматическим audit trail (журналом изменений). Каждое изменение сущности автоматически записывается в историю с информацией о том, кто, когда и что изменил.

## Когда использовать LoggedStorable

Используйте LoggedStorable для сущностей, где важна полная история изменений:

- **Workflow runs** — выполнение графов, логи операций
- **Audit logs** — журналы безопасности, доступа
- **Session logs** — история сессий пользователей
- **Transaction logs** — финансовые операции

## Базовый пример

### 1. Определение модели

```dart
import 'package:aq_schema/aq_schema.dart';

class WorkflowRun implements LoggedStorable {
  @override
  final String id;

  final String projectId;
  final String blueprintId;
  final WorkflowRunStatus status;
  final String logsJson;
  final DateTime createdAt;

  const WorkflowRun({
    required this.id,
    required this.projectId,
    required this.blueprintId,
    required this.status,
    required this.logsJson,
    required this.createdAt,
  });

  @override
  String get collectionName => 'workflow_runs';

  // Пустой Set = отслеживаем все поля
  @override
  Set<String> get trackedFields => {};

  @override
  Map<String, dynamic> get indexFields => {
    'projectId': projectId,
    'status': status.name,
  };

  @override
  Map<String, dynamic> toMap() => {
    'id': id,
    'projectId': projectId,
    'blueprintId': blueprintId,
    'status': status.name,
    'logsJson': logsJson,
    'createdAt': createdAt.toIso8601String(),
  };

  factory WorkflowRun.fromMap(Map<String, dynamic> map) {
    return WorkflowRun(
      id: map['id'] as String,
      projectId: map['projectId'] as String,
      blueprintId: map['blueprintId'] as String,
      status: WorkflowRunStatus.values.byName(map['status'] as String),
      logsJson: map['logsJson'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  static const kCollection = 'workflow_runs';
}
```

### 2. Создание репозитория

```dart
import 'package:dart_vault/dart_vault.dart';

// Подключение к Data Service
await Vault.connect('http://localhost:8765', tenantId: 'company-123');

// Создание репозитория
final runRepo = Vault.instance.logged<WorkflowRun>(
  collection: WorkflowRun.kCollection,
  fromMap: WorkflowRun.fromMap,
);
```

### 3. Сохранение с автоматическим логированием

```dart
// Создание новой сущности
final run = WorkflowRun(
  id: 'run-001',
  projectId: 'project-1',
  blueprintId: 'blueprint-1',
  status: WorkflowRunStatus.running,
  logsJson: '[]',
  createdAt: DateTime.now(),
);

// Сохранение — автоматически создаётся log entry с operation=created
await runRepo.save(run, actorId: 'worker-1');

// Обновление статуса
final updated = WorkflowRun(
  id: 'run-001',
  projectId: 'project-1',
  blueprintId: 'blueprint-1',
  status: WorkflowRunStatus.completed,
  logsJson: '["Step 1 done", "Step 2 done"]',
  createdAt: run.createdAt,
);

// Сохранение — автоматически создаётся log entry с operation=updated
await runRepo.save(updated, actorId: 'worker-1');
```

### 4. Просмотр истории изменений

```dart
// Получить всю историю
final history = await runRepo.getHistory('run-001');

for (final entry in history) {
  print('${entry.operation.name} by ${entry.changedBy} at ${entry.changedAt}');

  // Просмотр изменённых полей
  entry.diff.forEach((field, diff) {
    print('  $field: ${diff.before} → ${diff.after}');
  });
}

// Вывод:
// created by worker-1 at 2026-04-11 10:00:00
//   status: null → running
//   logsJson: null → []
// updated by worker-1 at 2026-04-11 10:05:00
//   status: running → completed
//   logsJson: [] → ["Step 1 done", "Step 2 done"]
```

## Продвинутые возможности

### Отслеживание только определённых полей

```dart
class AuditLog implements LoggedStorable {
  // ...

  @override
  Set<String> get trackedFields => {
    'userId',
    'action',
    'resourceId',
  };
  // Поля timestamp, metadata не будут попадать в diff
}
```

### Полные снимки состояния

Для возможности rollback нужны полные снимки:

```dart
final runRepo = Vault.instance.logged<WorkflowRun>(
  collection: WorkflowRun.kCollection,
  fromMap: WorkflowRun.fromMap,
  captureFullSnapshot: true, // Сохраняет полное состояние в каждом log entry
);
```

### Rollback к предыдущему состоянию

```dart
// Получить историю
final history = await runRepo.getHistory('run-001');

// Найти нужную версию
final targetEntry = history.firstWhere(
  (e) => e.changedAt.isBefore(DateTime(2026, 4, 11, 10, 0)),
);

// Откатиться к этой версии
await runRepo.rollbackTo(
  'run-001',
  targetEntry.entryId,
  actorId: 'admin',
);

// Rollback создаёт новый log entry с operation=rollback
```

### Получение состояния на момент времени

```dart
// Получить состояние сущности на 10:00
final stateAt10 = await runRepo.getStateAt(
  'run-001',
  DateTime(2026, 4, 11, 10, 0),
);

if (stateAt10 != null) {
  print('Status at 10:00: ${stateAt10.status}');
}
```

### Постраничный просмотр истории

```dart
final page = await runRepo.getHistoryPage(
  'run-001',
  VaultQuery()
    .where('operation', VaultOperator.equals, 'updated')
    .orderBy('changedAt', descending: true)
    .page(limit: 10, offset: 0),
);

print('Total updates: ${page.total}');
for (final entry in page.items) {
  print('Update at ${entry.changedAt}');
}
```

### Журнал всей коллекции

```dart
// Получить все изменения за период
final collectionLog = await runRepo.getCollectionLog(
  from: DateTime(2026, 4, 11),
  to: DateTime(2026, 4, 12),
);

print('Total changes in collection: ${collectionLog.length}');
```

## Архитектура

### Две коллекции

LoggedStorable автоматически создаёт две коллекции:

1. **`{collection}`** — текущее состояние сущностей
2. **`{collection}_log`** — история изменений (append-only)

Пример:
- `workflow_runs` — текущие runs
- `workflow_runs_log` — история изменений runs

### Структура LogEntry

```dart
class LogEntry {
  final String entryId;           // ID записи в истории
  final String entityId;          // ID сущности
  final String collectionId;      // Имя коллекции
  final String changedBy;         // Кто изменил (actorId)
  final DateTime changedAt;       // Когда изменил
  final LogOperation operation;   // created/updated/deleted/rollback
  final Map<String, FieldDiff> diff;  // Изменённые поля
  final Map<String, dynamic>? snapshot;  // Полный снимок (опционально)
  final String? rollbackToEntryId;  // Для rollback операций
}

class FieldDiff {
  final dynamic before;  // Значение до
  final dynamic after;   // Значение после
}
```

### Локальное vs Удалённое хранилище

LoggedStorable работает одинаково для обоих типов хранилищ:

**Локальное (InMemoryVaultStorage):**
- Log entries создаются в `LoggedRepositoryImpl.save()`
- Всё хранится в памяти

**Удалённое (RemoteVaultStorage):**
- Клиент вызывает RPC `put` с `actorId`
- Сервер создаёт log entry автоматически
- Log entries хранятся в PostgreSQL

Клиент **не знает** о деталях — всё работает через единый интерфейс.

## Регистрация на сервере

Для работы с удалённым хранилищем нужно зарегистрировать коллекцию на Data Service:

```dart
// В server_apps/aq_studio_data_service/bin/server.dart
registry.register(
  DomainRegistration(
    collection: WorkflowRun.kCollection,
    mode: StorageMode.logged,
    fromMap: WorkflowRun.fromMap,
  ),
);
```

## Best Practices

1. **Всегда указывайте actorId** — это критично для audit trail
2. **Используйте captureFullSnapshot** только если нужен rollback
3. **Ограничивайте trackedFields** для больших объектов
4. **Не храните sensitive данные** в diff — они остаются в истории навсегда
5. **Используйте индексы** для частых запросов по истории

## Примеры из реального кода

### WorkflowRun (aq_schema)

```dart
// pkgs/aq_schema/lib/data_layer/storable/workflow_run.dart
class WorkflowRun implements LoggedStorable {
  // Отслеживаем все изменения статуса, логов, результатов
  @override
  Set<String> get trackedFields => {};

  // Индексируем для быстрого поиска
  @override
  Map<String, dynamic> get indexFields => {
    'projectId': projectId,
    'blueprintId': blueprintId,
    'status': status.name,
  };
}
```

### SecuritySession (aq_security)

```dart
// pkgs/aq_security/lib/src/server/models/security_session.dart
class SecuritySession implements LoggedStorable {
  // Отслеживаем только критичные поля
  @override
  Set<String> get trackedFields => {
    'userId',
    'status',
    'lastActivityAt',
    'ipAddress',
  };
}
```

## Тестирование

```dart
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';

void main() {
  test('LoggedStorable создаёт историю', () async {
    final vault = Vault(
      storage: InMemoryVaultStorage(tenantId: 'test'),
      tenantId: 'test',
    );

    final repo = vault.logged<WorkflowRun>(
      collection: WorkflowRun.kCollection,
      fromMap: WorkflowRun.fromMap,
    );

    final run = WorkflowRun(/* ... */);
    await repo.save(run, actorId: 'test-user');

    final history = await repo.getHistory(run.id);
    expect(history.length, 1);
    expect(history.first.operation, LogOperation.created);
    expect(history.first.changedBy, 'test-user');
  });
}
```

## См. также

- [LOGGED_STORABLE_CONVENTION.md](../architecture/LOGGED_STORABLE_CONVENTION.md) — конвенции именования
- [LOGGED_STORABLE_IMPLEMENTATION_REPORT.md](../../LOGGED_STORABLE_IMPLEMENTATION_REPORT.md) — детали реализации
- [aq_schema LoggedStorable](../../../aq_schema/lib/data_layer/storable/logged_storable.dart) — интерфейс
