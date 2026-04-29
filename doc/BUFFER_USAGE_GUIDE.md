# Руководство по использованию буфера в dart_vault

## Обзор

`dart_vault` предоставляет два режима работы с удалённым хранилищем:

1. **С буфером** (`useBuffer: true`, по умолчанию) — для UI приложений
2. **Без буфера** (`useBuffer: false`) — для серверных приложений

## Когда использовать буфер

### ✅ UI приложения (AQ Studio)

**Используйте `useBuffer: true` (по умолчанию)**

```dart
// Подключение с буфером
await Vault.connect('http://localhost:8765', tenantId: userId);

// Все операции буферизуются локально
final project = AqStudioProject(...);
await projectRepo.save(project);

// Изменения отправляются на сервер при явном вызове flush()
await Vault.instance.buffer?.flush(AqStudioProject.kCollection);
```

**Преимущества:**
- **Offline-first**: работа без подключения к серверу
- **Batch операции**: множественные изменения отправляются одним запросом
- **Оптимизация**: меньше сетевых запросов
- **Rollback**: возможность отменить изменения до flush()

**Недостатки:**
- Требует явного вызова `flush()` для сохранения
- Дополнительная память для буфера
- Сложность синхронизации

### ✅ Серверные приложения (Worker, микросервисы)

**Используйте `useBuffer: false`**

```dart
// Подключение без буфера
await Vault.connect(
  'http://localhost:8765',
  tenantId: 'default',
  useBuffer: false,
);

// Все операции идут напрямую на Data Service
final project = AqStudioProject(...);
await projectRepo.save(project); // ← сразу отправляется на сервер
```

**Преимущества:**
- **Простота**: не нужно думать о flush()
- **Консистентность**: данные сразу в БД
- **Меньше памяти**: нет локального буфера
- **Предсказуемость**: операции выполняются немедленно

**Недостатки:**
- Больше сетевых запросов
- Нет offline режима

## Примеры использования

### UI приложение (AQ Studio)

```dart
void main() async {
  // Подключение с буфером (по умолчанию)
  await Vault.connect('http://localhost:8765', tenantId: currentUser.id);

  // Работа с данными
  final projectRepo = Vault.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Создание проекта (буферизуется локально)
  final project = AqStudioProject(...);
  await projectRepo.save(project);

  // Пользователь нажимает "Save" → flush()
  await Vault.instance.buffer?.flush(AqStudioProject.kCollection);
}
```

### Серверное приложение (Worker)

```dart
void main() async {
  // Подключение БЕЗ буфера
  await Vault.connect(
    'http://localhost:8765',
    tenantId: 'system',
    useBuffer: false, // ← важно!
  );

  // Работа с данными
  final runRepo = Vault.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  // Создание run (сразу отправляется на сервер)
  final run = WorkflowRun(...);
  await runRepo.save(run, actorId: 'worker');

  // flush() не нужен!
}
```

## Миграция существующего кода

### До (с буфером)

```dart
await Vault.connect('http://localhost:8765');

final project = AqStudioProject(...);
await projectRepo.save(project);

// Нужен flush()
await Vault.instance.buffer?.flush(AqStudioProject.kCollection);
```

### После (без буфера для серверов)

```dart
await Vault.connect('http://localhost:8765', useBuffer: false);

final project = AqStudioProject(...);
await projectRepo.save(project); // ← сразу на сервер

// flush() не нужен!
```

## Проверка наличия буфера

```dart
if (Vault.instance.buffer != null) {
  print('Буфер активен');
  // Нужно вызывать flush()
} else {
  print('Прямое подключение');
  // flush() не нужен
}
```

## Рекомендации

1. **UI приложения**: всегда используйте буфер (`useBuffer: true`)
2. **Серверные приложения**: всегда отключайте буфер (`useBuffer: false`)
3. **Тесты**: используйте `useBuffer: false` для простоты
4. **Миграция**: добавьте `useBuffer: false` в существующие серверные приложения

## Архитектурное решение

Параметр `useBuffer` был добавлен для решения проблемы избыточной буферизации в серверных приложениях. Это позволяет:

- **UI приложениям** использовать offline-first подход с буфером
- **Серверным приложениям** работать напрямую с Data Service без буфера
- **Сохранить обратную совместимость** (по умолчанию `useBuffer: true`)

## См. также

- [Vault API Documentation](lib/client/vault.dart)
- [LocalBufferVaultStorage](lib/storage/local_buffer_vault_storage.dart)
- [RemoteVaultStorage](lib/client/remote/remote_vault_storage.dart)
