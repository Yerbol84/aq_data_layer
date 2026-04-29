# Требования к дата-слою от слоя безопасности

**Дата**: 2026-04-21  
**Клиент**: aq_security package  
**Статус**: Требует реализации

---

## Бизнес-контекст

Слой безопасности управляет критичными для compliance сущностями:
- **Сессии пользователей** — должны автоматически истекать по времени
- **API ключи** — имеют срок действия и должны автоматически деактивироваться
- **Временные роли** — назначаются на ограниченный период (emergency access, trial)
- **Конфигурации безопасности** (роли, политики) — требуют полного audit trail и возможности отката

**Проблема**: Текущие возможности дата-слоя не покрывают эти бизнес-требования.

---

## Use Case 1: Автоматическая expiration сущностей

### Бизнес-сценарий

**Актор**: Система безопасности  
**Цель**: Автоматически истекать временные сущности без ручного вмешательства

**Примеры**:

1. **Сессия пользователя**:
   - Пользователь логинится → создаётся сессия с `expiresAt = now + 30 days`
   - Через 30 дней сессия должна **автоматически** перейти в статус `expired`
   - При попытке использовать expired сессию → система возвращает ошибку
   - **Audit trail**: Переход `active → expired` должен быть залогирован

2. **API ключ с ограниченным сроком**:
   - Создаётся тестовый API ключ с `expiresAt = now + 7 days`
   - Через 7 дней ключ должен **автоматически** стать неактивным
   - При попытке использовать expired ключ → система возвращает ошибку
   - **Audit trail**: Деактивация должна быть залогирована

3. **Временная роль (emergency access)**:
   - Админ назначает роль `incident_responder` с `expiresAt = now + 4 hours`
   - Через 4 часа назначение должно **автоматически** удалиться
   - Пользователь теряет права доступа
   - **Audit trail**: Удаление должно быть залогировано

### Текущая проблема

Клиент (aq_security) вынужден **вручную** проверять expiration:

```dart
// ПЛОХО: Клиент делает работу дата-слоя
Future<int> purgeExpired() async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final all = await _repo.findAll(
    query: VaultQuery().where('status', VaultOperator.equals, 'active'),
  );
  var count = 0;
  for (final storable in all) {
    final s = storable.domain;
    if (s.expiresAt < now) {
      await _repo.save(
        StorableSession(s.copyWith(status: SessionStatus.expired)),
        actorId: 'system',
      );
      count++;
    }
  }
  return count;
}
```

**Проблемы**:
- Клиент должен периодически вызывать `purgeExpired()`
- Между проверками expired сущности остаются активными
- Нет гарантии консистентности
- Дублирование логики в каждом репозитории

### Требуемое поведение

**Клиент хочет**:

```dart
// ХОРОШО: Дата-слой делает всё сам
final session = await sessionRepo.findById('session_123');
// Если session.expiresAt < now:
//   - Дата-слой автоматически вызывает session.onExpire()
//   - Сохраняет expired состояние
//   - Создаёт log entry с actorId: 'system'
//   - Возвращает expired сессию клиенту

if (session?.status == SessionStatus.expired) {
  throw SessionExpiredException();
}
```

**Клиент НЕ хочет**:
- Вручную проверять `expiresAt`
- Запускать background jobs для expiration
- Дублировать логику в каждом репозитории

### Требования к интерфейсу

#### Для LoggedStorable (сущности с audit trail)

```dart
abstract interface class LoggedStorable extends Storable {
  // Existing...
  Set<String> get trackedFields;
  
  /// Timestamp когда сущность должна истечь (Unix seconds)
  /// null = без expiration
  int? get expiresAt => null;
  
  /// Callback для перехода в expired состояние
  /// Вызывается дата-слоем автоматически когда now >= expiresAt
  /// Возвращает новое состояние сущности
  /// null = удалить сущность вместо изменения статуса
  LoggedStorable? onExpire() => null;
}
```

**Поведение дата-слоя**:
1. При любом запросе (`findById`, `findAll`, `findPage`) проверять `expiresAt`
2. Если `now >= expiresAt`:
   - Вызвать `onExpire()`
   - Сохранить результат с `actorId: 'system'`
   - Создать log entry с `reason: 'auto_expired'`
3. Вернуть expired состояние клиенту

#### Для DirectStorable (простые сущности)

```dart
abstract interface class DirectStorable extends Storable {
  // Existing...
  
  /// Timestamp когда сущность должна быть удалена (Unix seconds)
  /// null = без expiration
  int? get expiresAt => null;
}
```

**Поведение дата-слоя**:
1. При любом запросе автоматически фильтровать `expiresAt < now`
2. Background job периодически удаляет expired записи из БД
3. Клиент никогда не видит expired записи

### Примеры использования

#### Пример 1: Session (LoggedStorable)

```dart
final class StorableSession implements LoggedStorable {
  StorableSession(this._session);
  final AqSession _session;
  AqSession get domain => _session;
  
  @override
  int? get expiresAt => _session.expiresAt;
  
  @override
  StorableSession? onExpire() {
    // Переход в expired состояние
    return StorableSession(_session.copyWith(
      status: SessionStatus.expired,
    ));
  }
  
  @override
  Set<String> get trackedFields => {
    'status',
    'lastSeenAt',
    'revokedAt',
    'revokedReason',
  };
}
```

**Клиентский код**:
```dart
// Просто читаем сессию
final session = await sessionRepo.findById('session_123');

// Дата-слой уже сделал всё:
// - Проверил expiresAt
// - Вызвал onExpire() если нужно
// - Сохранил expired состояние
// - Создал log entry

if (session?.status == SessionStatus.expired) {
  throw SessionExpiredException();
}
```

#### Пример 2: UserRole (DirectStorable)

```dart
final class StorableUserRole implements DirectStorable {
  StorableUserRole(this._userRole);
  final AqUserRole _userRole;
  AqUserRole get domain => _userRole;
  
  @override
  int? get expiresAt => _userRole.expiresAt;
  
  // onExpire не нужен - дата-слой просто удалит запись
}
```

**Клиентский код**:
```dart
// Просто читаем назначения ролей
final roles = await userRoleRepo.findAll(
  query: VaultQuery().where('userId', VaultOperator.equals, userId),
);

// Дата-слой уже отфильтровал expired назначения
// Клиент видит только активные роли
```

---

## Use Case 2: Версионирование конфигураций безопасности

### Бизнес-сценарий

**Актор**: Администратор безопасности  
**Цель**: Безопасно изменять конфигурации безопасности с возможностью отката

**Примеры**:

1. **Изменение прав роли**:
   - Админ хочет добавить новое право `financial:read` в роль `accountant`
   - Перед применением в production нужно протестировать в staging
   - Если что-то пошло не так → откатить изменения
   - **Compliance**: Кто, когда и почему изменил права роли?

2. **Изменение политики доступа**:
   - Админ хочет ограничить доступ к финансовым данным только рабочими часами
   - Создаёт draft политики с новыми условиями
   - Тестирует в staging
   - Публикует в production
   - **Audit**: Полная история изменений условий политики

3. **Откат после инцидента**:
   - После security incident обнаружено, что изменения прав роли `developer` привели к утечке
   - Нужно **немедленно** откатить роль к состоянию до инцидента
   - **Forensics**: Какие права были у роли в момент инцидента?

### Текущая проблема

Роли и политики хранятся как DirectStorable:
- Нет истории изменений
- Нет возможности отката
- Нет branching для тестирования
- Нет audit trail для compliance

### Требуемое поведение

**Клиент хочет**:

```dart
// 1. Создать draft роли с новыми правами
final draftNode = await roleRepo.createDraftFrom(
  'role_accountant',
  StorableRole(role.copyWith(
    permissions: [...existingPerms, 'financial:read'],
  )),
);

// 2. Протестировать в staging (через branching)
await roleRepo.createBranch(
  draftNode.id,
  branchName: 'staging',
  model: StorableRole(role),
);

// 3. Опубликовать в production
await roleRepo.publishDraft(
  draftNode.id,
  increment: IncrementType.minor, // 1.2.0 → 1.3.0
);

// 4. Получить историю изменений
final history = await roleRepo.getVersionHistory('role_accountant');
// [v1.0.0, v1.1.0, v1.2.0, v1.3.0]

// 5. Откатить к предыдущей версии
await roleRepo.rollbackTo('role_accountant', history[2].id);
```

**Клиент НЕ хочет**:
- Вручную создавать таблицы для истории
- Реализовывать branching логику
- Управлять версиями вручную

### Требования к интерфейсу

**Использовать существующий VersionedRepository** — он уже предоставляет всё необходимое:

```dart
abstract interface class VersionedRepository<T extends VersionedStorable> {
  // Lifecycle
  Future<VersionNode> createEntity(T model);
  Future<VersionNode> createDraftFrom(String parentNodeId, T model);
  Future<void> updateDraft(String nodeId, T model);
  Future<VersionNode> publishDraft(String nodeId, {required IncrementType increment});
  
  // Branching
  Future<VersionNode> createBranch(String parentNodeId, {required String branchName, required T model});
  Future<VersionNode> mergeToMain(String entityId, {required String sourceBranch, ...});
  Future<List<String>> listBranches(String entityId);
  
  // History
  Future<List<VersionNode>> getVersionHistory(String entityId);
  Future<VersionNode?> getCurrent(String entityId);
  
  // Rollback (через createDraftFrom + publishDraft)
}
```

**Требование**: Интерфейс уже есть, нужно только мигрировать сущности.

### Примеры использования

#### Пример 1: Роль (VersionedStorable)

```dart
final class StorableRole implements VersionedStorable {
  StorableRole(this._role);
  final AqRole _role;
  AqRole get domain => _role;
  
  @override
  String get id => _role.id;
  
  @override
  String get entityId => _role.id; // Все версии одной роли
  
  @override
  String get ownerId => _role.tenantId ?? 'platform';
  
  @override
  List<String> get sharedWith => _role.tenantId == null
    ? ['*'] // System roles видны всем
    : [_role.tenantId!]; // Tenant roles только своему tenant
  
  @override
  Map<String, dynamic> toMap() => _role.toJson();
  
  @override
  Map<String, dynamic> get indexFields => {
    'name': _role.name,
    'tenantId': _role.tenantId ?? '',
    'isSystem': _role.isSystem,
  };
  
  @override
  String get collectionName => SecurityCollections.roles;
}
```

**Клиентский код**:
```dart
// Создание роли
final node = await roleRepo.createEntity(StorableRole(role));

// Изменение прав (draft)
final draft = await roleRepo.createDraftFrom(
  node.id,
  StorableRole(role.copyWith(permissions: [...newPerms])),
);

// Публикация
await roleRepo.publishDraft(draft.id, increment: IncrementType.minor);

// История
final history = await roleRepo.getVersionHistory(role.id);

// Откат
final oldVersion = history.firstWhere((v) => v.semver == '1.2.0');
final rollbackDraft = await roleRepo.createDraftFrom(
  oldVersion.id,
  StorableRole(role), // Данные из старой версии
);
await roleRepo.publishDraft(rollbackDraft.id, increment: IncrementType.patch);
```

---

## Итоговые требования к дата-слою

### Требование 1: TTL Support

**Приоритет**: Высокий  
**Затронутые интерфейсы**: `LoggedStorable`, `DirectStorable`

**Что нужно**:
1. Добавить поле `expiresAt` в интерфейсы
2. Для `LoggedStorable`: добавить callback `onExpire()`
3. Реализовать автоматическую проверку expiration при запросах
4. Реализовать background job для очистки expired записей

**Бизнес-ценность**:
- Автоматическая expiration сессий, API ключей, временных ролей
- Консистентность: expiration происходит в момент доступа
- Меньше кода в клиентских пакетах
- Audit trail для expiration событий

### Требование 2: Подтверждение работы VersionedRepository

**Приоритет**: Средний  
**Затронутые интерфейсы**: `VersionedRepository`

**Что нужно**:
- Подтвердить, что текущая реализация поддерживает:
  - Lifecycle: draft → published → snapshot
  - Branching + merging
  - History + rollback
  - ACL через `ownerId` + `sharedWith`

**Бизнес-ценность**:
- Версионирование конфигураций безопасности
- Branching для тестирования изменений
- Rollback после инцидентов
- Compliance: полная история изменений

---

## Acceptance Criteria

### Для TTL Support

**Given**: Сущность с `expiresAt = now + 1 hour`  
**When**: Клиент читает сущность через 2 часа  
**Then**: 
- Для `LoggedStorable`: Дата-слой вызывает `onExpire()`, сохраняет результат, создаёт log entry
- Для `DirectStorable`: Дата-слой возвращает `null` (сущность отфильтрована)

**Given**: Сессия с `expiresAt = now + 30 days`  
**When**: Через 30 дней клиент вызывает `findById(sessionId)`  
**Then**: 
- Дата-слой вызывает `session.onExpire()`
- Сохраняет сессию со статусом `expired`
- Создаёт log entry с `actorId: 'system'`, `reason: 'auto_expired'`
- Возвращает expired сессию клиенту

### Для VersionedRepository

**Given**: Роль с правами `['projects:read']`  
**When**: Админ создаёт draft с правами `['projects:read', 'projects:write']`  
**Then**: 
- Создаётся новый DRAFT node
- Старая версия остаётся PUBLISHED
- История содержит обе версии

**Given**: Роль версии 1.2.0  
**When**: Админ делает rollback к версии 1.0.0  
**Then**: 
- Создаётся новый DRAFT из версии 1.0.0
- После публикации версия становится 1.2.1 (patch increment)
- История содержит все версии: 1.0.0, 1.1.0, 1.2.0, 1.2.1

---

## Вопросы к дата-слою

1. **TTL Support**: Возможна ли реализация в текущей архитектуре?
2. **Performance**: Как проверка `expiresAt` повлияет на производительность запросов?
3. **Background Job**: Как часто должен запускаться job для очистки expired записей?
4. **VersionedRepository**: Подтверждаете ли, что текущая реализация поддерживает все требуемые use cases?
5. **Migration**: Как мигрировать существующие DirectStorable → VersionedStorable без потери данных?

---

## Контакт

**Клиент**: aq_security package  
**Ответственный**: Security Layer Team  
**Дата создания**: 2026-04-21
