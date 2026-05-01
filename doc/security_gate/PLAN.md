# Security Gate — План интеграции в AQ Data Layer

> Дата: 2026-04-30  
> Статус: планирование  
> Пакеты: `aq_schema` (контракты), `aq_data_layer` (интеграция)

---

## 1. Контекст и философия

### Три вида данных в каждом запросе

```
┌─────────────────────────────────────────────────────────┐
│  CREDENTIALS (кто делает запрос)                        │
│  AqTokenClaims { sub, tid, roles, scopes, perms }       │
│  Источник: JWT токен в Authorization header             │
├─────────────────────────────────────────────────────────┤
│  RESOURCE (над чем)                                     │
│  "collection:entityId"  →  "projects:proj-123"          │
│  Источник: параметры RPC запроса                        │
├─────────────────────────────────────────────────────────┤
│  ACTION (что делает)                                    │
│  "read" | "write" | "delete" | "publish" | "grant"      │
│  Источник: имя операции в RPC запросе                   │
└─────────────────────────────────────────────────────────┘
```

### Принцип работы data layer

Data layer — **тупой исполнитель**. Он не знает о ролях, политиках, JWT.  
Он только спрашивает: **"Можно?"** и получает типобезопасный ответ.

```
Client → [token + collection + operation + entityId]
  → Server RPC
    → extractClaims(headers)       // кто?
    → canRead/canWrite/canDelete() // можно?
    → AccessDecision.allowed       // да/нет
      → execute or throw SecurityException
```

### Два режима

| Режим | Как включить | Поведение |
|---|---|---|
| **Без защиты** (dev/internal) | `IVaultSecurityProtocol.instance == null` | Всё разрешено |
| **С защитой** (production) | `IVaultSecurityProtocol.initialize(impl)` | Проверяет каждый запрос |

---

## 2. Что уже есть в `aq_schema` (не трогаем)

Вся архитектура уже продумана и реализована:

```
aq_schema/lib/security/
  interfaces/
    clients_protocols/
      i_data_layer_as_client_secure_protocol.dart  ← IVaultSecurityProtocol
      i_auth_context.dart                          ← IAuthContext (ambient)
      noop_vault_security_protocol.dart            ← NoOpVaultSecurityProtocol
      mocks/
        mock_vault_security_protocol.dart          ← MockVaultSecurityProtocol
        test_tokens.dart                           ← TestTokens, TestUsers
    i_security_service.dart                        ← ISecurityService
    i_resource_permission_service.dart
    i_policy_service.dart
    i_audit_service.dart
  models/
    access_context.dart    ← AccessContext { userId, tenantId, resource, action }
    access_decision.dart   ← AccessDecision { allowed, reason }
    aq_token_claims.dart   ← AqTokenClaims { sub, tid, roles, scopes }
    aq_permission.dart
    aq_role.dart
    aq_policy.dart
    ...
```

**Ключевые типы:**

```dart
// Три слоя данных запроса
AccessContext {
  userId,      // credentials
  tenantId,    // credentials
  resource,    // "projects:proj-123"
  action,      // "write"
  userRoles,   // credentials
  userScopes,  // credentials
  resourceAttributes: { ownerId: '...' }  // для owner-check
}

// Решение
AccessDecision {
  allowed: bool,
  reason: String?,
  matchedRoles, matchedPermissions, appliedPolicies
}

// Протокол для data layer
IVaultSecurityProtocol {
  extractClaims(headers) → AqTokenClaims?
  canRead(claims, collection, entityId?) → AccessDecision
  canWrite(claims, collection, entityId?, data) → AccessDecision
  canDelete(claims, collection, entityId) → AccessDecision
  canPublish(claims, collection, entityId) → AccessDecision
  canGrant(claims, collection, entityId, targetUserId, level) → AccessDecision
}
```

---

## 3. Что нужно сделать в `aq_data_layer`

### 3.1 Клиент: передача токена в RPC

`RemoteVaultStorage` должен добавлять `Authorization` header в каждый HTTP запрос.  
Токен берётся из `IAuthContext.instance?.currentToken`.

**Файл:** `lib/client/remote/remote_vault_storage.dart`

```dart
// Добавить в конструктор
final String? authToken;  // опционально

// Добавить в каждый HTTP запрос
headers: {
  'Content-Type': 'application/json',
  if (authToken != null) 'Authorization': 'Bearer $authToken',
}
```

**Файл:** `lib/client/vault.dart` — `Vault.remote()` принимает `authToken`  
**Файл:** `lib/dart_vault.dart` — `initializeDataLayer()` читает токен из `IAuthContext`

### 3.2 Сервер: извлечение токена из запроса

`VaultRegistry.dispatch()` должен принимать `headers` и передавать в security protocol.

**Файл:** `lib/deploy/vault_registry.dart`

```dart
Future<dynamic> dispatch({
  required String collection,
  required String operation,
  required Map<String, dynamic> args,
  required String tenantId,
  Map<String, String> headers = const {},  // ← добавить
}) async {
  final protocol = IVaultSecurityProtocol.instance;
  if (protocol != null) {
    final claims = await protocol.extractClaims(headers);
    final action = _operationToAction(operation);
    final entityId = args['id'] as String? ?? args['entityId'] as String?;
    
    final decision = await _checkAccess(protocol, claims, collection, action, entityId, args);
    if (!decision.allowed) {
      throw VaultAccessDeniedException(decision.reason ?? 'Access denied');
    }
  }
  // ... существующая логика dispatch
}
```

**Файл:** `example/stack/server/main.dart` — передавать headers из HTTP запроса в `dispatch()`

### 3.3 Маппинг операций → действия

```dart
String _operationToAction(String operation) => switch (operation) {
  'findById' || 'findAll' || 'findPage' || 'count' || 
  'listVersions' || 'getCurrent' || 'getLatestPublished' ||
  'getHistory' => 'read',
  
  'save' || 'updateDraft' || 'createEntity' || 'rollbackTo' => 'write',
  
  'delete' || 'deleteEntity' => 'delete',
  
  'publishDraft' => 'publish',
  
  'grantAccess' => 'grant',
  
  _ => 'write',  // safe default
};
```

### 3.4 Owner-check через resourceAttributes

Для проверки "является ли actor владельцем" security service нужен `ownerId`.  
Data layer должен передавать его в `resourceAttributes` если знает:

```dart
// При canWrite/canDelete — загрузить текущую запись и передать ownerId
final existing = await storage.get(collection, entityId);
final ownerId = existing?['ownerId'] as String?;

final decision = await protocol.canWrite(
  claims: claims,
  collection: collection,
  entityId: entityId,
  data: args,
  // resourceAttributes передаётся через AccessContext внутри реализации
);
```

**Важно:** `IVaultSecurityProtocol` сам решает нужен ли ему `ownerId` — data layer просто передаёт что знает.

---

## 4. Архитектура потока запроса

```
Flutter/Dart Client
  │
  │  IAuthContext.instance.currentToken → "Bearer eyJ..."
  │
  ▼
RemoteVaultStorage.rpc()
  │  headers: { Authorization: "Bearer eyJ..." }
  │  body: { collection, operation, args, tenantId }
  │
  ▼  HTTP POST /api/v1/rpc
Server (shelf)
  │
  │  request.headers['authorization'] → передать в dispatch()
  │
  ▼
VaultRegistry.dispatch(headers: {...})
  │
  ├─ IVaultSecurityProtocol.instance == null?
  │    └─ YES → пропустить проверку (dev mode)
  │
  ├─ protocol.extractClaims(headers) → AqTokenClaims
  │
  ├─ _operationToAction(operation) → "read" | "write" | ...
  │
  ├─ protocol.canRead/canWrite/canDelete(claims, collection, entityId)
  │    └─ AccessDecision { allowed: false } → throw VaultAccessDeniedException
  │
  └─ Выполнить операцию → вернуть результат
```

---

## 5. Что НЕ делаем сейчас

- **`RemoteSecurityGate`** (реальный security service) — это `aq_security` пакет, не наша задача
- **RBAC правила** — логика внутри `MockVaultSecurityProtocol` / реальной реализации
- **Шифрование полей** — `encryptSensitiveFields` / `decryptSensitiveFields` — отдельная задача
- **Rate limiting** — `checkRateLimit` — отдельная задача
- **Изменение клиентских сигнатур репозиториев** — не трогаем

---

## 6. Сценарии для тестирования

### Сценарий A: Без защиты (dev mode)
- `IVaultSecurityProtocol.instance == null`
- Все операции проходят без проверки
- Ожидание: всё работает как сейчас

### Сценарий B: Mock protection — admin
- `IVaultSecurityProtocol.initialize(MockVaultSecurityProtocol())`
- Клиент передаёт `Authorization: Bearer test-admin-token`
- Ожидание: все операции разрешены

### Сценарий C: Mock protection — readonly user
- Клиент передаёт `Authorization: Bearer test-readonly-token`
- Ожидание: `findAll`, `findById` — OK; `save`, `delete` — `SecurityException`

### Сценарий D: Mock protection — blocked user
- Клиент передаёт `Authorization: Bearer test-blocked-token`
- Ожидание: все операции — `SecurityException`

### Сценарий E: Без токена (anonymous)
- Клиент не передаёт `Authorization` header
- Ожидание: зависит от политики (в mock — разрешено или нет)

---

## 7. Порядок реализации

```
Шаг 1: VaultRegistry.dispatch() принимает headers + вызывает IVaultSecurityProtocol
Шаг 2: server/main.dart передаёт headers из HTTP запроса
Шаг 3: RemoteVaultStorage добавляет Authorization header
Шаг 4: initializeDataLayer() читает токен из IAuthContext
Шаг 5: Написать main_security.dart — сценарии A/B/C/D
Шаг 6: Dockerfile.security + docker-compose сервис
Шаг 7: Запустить, убедиться что все сценарии проходят
```

---

## 8. Изменяемые файлы

| Файл | Изменение |
|---|---|
| `lib/deploy/vault_registry.dart` | `dispatch()` + `headers` + security check |
| `lib/client/remote/remote_vault_storage.dart` | `authToken` field + header в запросах |
| `lib/client/vault.dart` | `Vault.remote()` принимает `authToken` |
| `lib/dart_vault.dart` | `initializeDataLayer()` читает `IAuthContext` |
| `example/stack/server/main.dart` | передавать headers в `dispatch()` |
| `example/stack/console_client/main_security.dart` | новый файл — сценарии |
| `example/stack/console_client/Dockerfile.security` | новый файл |
| `example/stack/docker-compose.yml` | добавить `security` сервис |

---

## 9. Важные замечания

**Backward compatibility:** Все изменения обратно совместимы.  
- `headers` в `dispatch()` — опциональный параметр с дефолтом `const {}`
- `authToken` в `RemoteVaultStorage` — опциональный
- `IVaultSecurityProtocol.instance == null` → dev mode, всё разрешено

**Thread safety:** `IVaultSecurityProtocol` — singleton, но `extractClaims` вызывается  
с конкретными headers каждого запроса → thread-safe для multi-tenant сервера.

**Serverless mode:** InMemory vault не проходит через `VaultRegistry.dispatch()`,  
поэтому security gate там не применяется. Это корректно — serverless = dev/test.
