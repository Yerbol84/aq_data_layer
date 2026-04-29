# Security Protocol для dart_vault

## Концепция

**Security Protocol** — это интерфейс-порт для системы безопасности. Data layer использует этот интерфейс, но **НЕ реализует** его.

### Принципы

1. **Инверсия зависимостей** — data layer зависит от интерфейса, не от реализации
2. **Необязательный** — если не инициализирован, все операции разрешены (NoOp)
3. **Универсальный** — не знает о бизнес-логике, работает только с коллекциями и операциями
4. **Реализация отдельно** — в `aq_security`, `aq_auth_service` или вашем сервисе

---

## Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                        │
│  (aq_studio, aq_graph_engine, your_app)                    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ использует
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                    dart_vault (Data Layer)                  │
│                                                             │
│  ┌──────────────┐         зависит от        ┌───────────┐ │
│  │ VaultStorage │◄────────────────────────────│ IVaultSecurity│ │
│  │              │                            │ Protocol  │ │
│  └──────────────┘                            └─────▲─────┘ │
│                                                    │        │
└────────────────────────────────────────────────────┼────────┘
                                                     │
                                                     │ реализует
                         ┌───────────────────────────┴─────────┐
                         │                                     │
              ┌──────────▼──────────┐           ┌─────────────▼────────┐
              │ NoOpSecurityProtocol│           │ MySecurityService    │
              │ (всё разрешено)     │           │ (ваша реализация)    │
              └─────────────────────┘           └──────────────────────┘
```

---

## Интерфейс IVaultSecurityProtocol

### 1. Authentication — Кто ты?

```dart
Future<SecurityContext> authenticate(SecurityRequest request);
```

**Задача:** Извлечь из HTTP запроса информацию о пользователе.

**Входные данные:**
- JWT token из `Authorization` header
- API key
- IP адрес, User Agent

**Выходные данные:**
- `SecurityContext` с userId, tenantId, roles, permissions

**Пример реализации:**

```dart
class JWTSecurityService implements IVaultSecurityProtocol {
  final JWTValidator validator;

  @override
  Future<SecurityContext> authenticate(SecurityRequest request) async {
    // 1. Извлечь токен
    final authHeader = request.headers['Authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw SecurityException('Missing or invalid Authorization header');
    }

    final token = authHeader.substring(7);

    // 2. Валидировать JWT
    final payload = await validator.verify(token);

    // 3. Извлечь данные
    return SecurityContext(
      userId: payload['sub'] as String,
      tenantId: payload['tenant_id'] as String,
      roles: (payload['roles'] as List).cast<String>(),
      permissions: (payload['permissions'] as List).cast<String>(),
      metadata: {
        'ip': request.ip,
        'userAgent': request.userAgent,
        'sessionId': payload['session_id'],
      },
    );
  }
}
```

---

### 2. Authorization — Что ты можешь делать?

```dart
Future<bool> authorize(SecurityContext context, SecurityAction action);
```

**Задача:** Проверить права доступа для конкретного действия.

**Входные данные:**
- `SecurityContext` — кто делает запрос
- `SecurityAction` — что хочет сделать (read, write, delete, etc.)

**Выходные данные:**
- `true` если разрешено
- `false` если запрещено

**Пример реализации:**

```dart
@override
Future<bool> authorize(SecurityContext context, SecurityAction action) async {
  // 1. Админы могут всё
  if (context.isAdmin) return true;

  // 2. Проверить роли
  switch (action.operation) {
    case 'read':
      return context.hasPermission('read:${action.collection}');

    case 'write':
      return context.hasPermission('write:${action.collection}');

    case 'delete':
      // Только владелец или админ
      if (action.entityId != null) {
        final owner = await getEntityOwner(action.collection, action.entityId!);
        return owner == context.userId || context.isAdmin;
      }
      return false;

    case 'publish':
      // Только роль 'publisher'
      return context.hasRole('publisher') || context.isAdmin;

    default:
      return false;
  }
}
```

---

### 3. Audit — Что произошло?

```dart
Future<void> audit(
  SecurityContext context,
  SecurityAction action,
  AuditResult result,
);
```

**Задача:** Записать событие аудита для compliance.

**Пример реализации:**

```dart
@override
Future<void> audit(
  SecurityContext context,
  SecurityAction action,
  AuditResult result,
) async {
  await auditLogger.log(AuditEvent(
    timestamp: DateTime.now(),
    userId: context.userId,
    tenantId: context.tenantId,
    operation: action.operation,
    collection: action.collection,
    entityId: action.entityId,
    success: result.success,
    errorMessage: result.errorMessage,
    metadata: {
      ...context.metadata,
      ...?result.metadata,
    },
  ));
}
```

---

### 4. Rate Limiting — Не слишком ли часто?

```dart
Future<RateLimitResult> checkRateLimit(
  SecurityContext context,
  RateLimitKey key,
);
```

**Задача:** Защита от DoS атак и abuse.

**Пример реализации:**

```dart
@override
Future<RateLimitResult> checkRateLimit(
  SecurityContext context,
  RateLimitKey key,
) async {
  final limiter = rateLimiters[key.type];
  if (limiter == null) {
    return RateLimitResult(exceeded: false, remaining: 999, limit: 999);
  }

  final result = await limiter.check(key.value);

  if (result.exceeded) {
    // Записать в audit log
    await audit(
      context,
      SecurityAction(operation: 'rate_limit_exceeded', collection: 'system'),
      AuditResult.failure('Rate limit exceeded'),
    );
  }

  return result;
}
```

---

### 5. Validation — Корректны ли данные?

```dart
Future<ValidationResult> validateInput(
  SecurityContext context,
  String collection,
  Map<String, dynamic> data,
);
```

**Задача:** Защита от SQL injection, XSS, invalid data.

**Пример реализации:**

```dart
@override
Future<ValidationResult> validateInput(
  SecurityContext context,
  String collection,
  Map<String, dynamic> data,
) async {
  final errors = <ValidationError>[];

  // 1. Проверить на SQL injection
  for (final entry in data.entries) {
    if (entry.value is String) {
      if (containsSQLInjection(entry.value)) {
        errors.add(ValidationError(
          field: entry.key,
          message: 'Potential SQL injection detected',
          code: 'SQL_INJECTION',
        ));
      }
    }
  }

  // 2. Проверить на XSS
  for (final entry in data.entries) {
    if (entry.value is String) {
      if (containsXSS(entry.value)) {
        errors.add(ValidationError(
          field: entry.key,
          message: 'Potential XSS detected',
          code: 'XSS',
        ));
      }
    }
  }

  // 3. Проверить JSON schema (если есть)
  final schema = await getCollectionSchema(collection);
  if (schema != null) {
    final schemaErrors = validateAgainstSchema(data, schema);
    errors.addAll(schemaErrors);
  }

  return errors.isEmpty
      ? ValidationResult.valid()
      : ValidationResult.invalid(errors);
}
```

---

### 6. Encryption — Нужно ли шифровать?

```dart
Future<Map<String, dynamic>> encryptSensitiveFields(
  SecurityContext context,
  String collection,
  Map<String, dynamic> data,
);
```

**Задача:** Шифрование чувствительных данных (PII, credentials).

**Пример реализации:**

```dart
@override
Future<Map<String, dynamic>> encryptSensitiveFields(
  SecurityContext context,
  String collection,
  Map<String, dynamic> data,
) async {
  final sensitiveFields = getSensitiveFields(collection);
  if (sensitiveFields.isEmpty) return data;

  final encrypted = Map<String, dynamic>.from(data);

  for (final field in sensitiveFields) {
    if (encrypted.containsKey(field) && encrypted[field] != null) {
      final plaintext = encrypted[field].toString();
      encrypted[field] = await encryptor.encrypt(plaintext, context.tenantId);
    }
  }

  return encrypted;
}

@override
Future<Map<String, dynamic>> decryptSensitiveFields(
  SecurityContext context,
  String collection,
  Map<String, dynamic> data,
) async {
  final sensitiveFields = getSensitiveFields(collection);
  if (sensitiveFields.isEmpty) return data;

  final decrypted = Map<String, dynamic>.from(data);

  for (final field in sensitiveFields) {
    if (decrypted.containsKey(field) && decrypted[field] != null) {
      final ciphertext = decrypted[field].toString();
      decrypted[field] = await encryptor.decrypt(ciphertext, context.tenantId);
    }
  }

  return decrypted;
}
```

---

## Интеграция с VaultStorage

### PostgresVaultStorage

```dart
class PostgresVaultStorage implements VaultStorage {
  final Pool pool;
  final String tenantId;
  final IVaultSecurityProtocol? securityProtocol;

  PostgresVaultStorage({
    required this.pool,
    required this.tenantId,
    this.securityProtocol, // Необязательный
  });

  @override
  Future<void> put(String collection, String id, Map<String, dynamic> data) async {
    // 1. Authenticate (если есть security)
    SecurityContext? context;
    if (securityProtocol != null) {
      context = await securityProtocol!.authenticate(
        SecurityRequest(headers: {/* из HTTP request */}),
      );
    }

    // 2. Authorize
    if (securityProtocol != null && context != null) {
      final canWrite = await securityProtocol!.authorize(
        context,
        SecurityAction.write(collection: collection, entityId: id),
      );

      if (!canWrite) {
        throw SecurityException('Access denied');
      }
    }

    // 3. Rate limit
    if (securityProtocol != null && context != null) {
      final rateLimit = await securityProtocol!.checkRateLimit(
        context,
        RateLimitKey.userId(context.userId),
      );

      if (rateLimit.exceeded) {
        throw RateLimitException(
          'Too many requests',
          retryAfter: rateLimit.retryAfter!,
        );
      }
    }

    // 4. Validate
    if (securityProtocol != null && context != null) {
      final validation = await securityProtocol!.validateInput(
        context,
        collection,
        data,
      );

      if (!validation.isValid) {
        throw ValidationException(validation.errors);
      }
    }

    // 5. Encrypt
    Map<String, dynamic> finalData = data;
    if (securityProtocol != null && context != null) {
      finalData = await securityProtocol!.encryptSensitiveFields(
        context,
        collection,
        data,
      );
    }

    // 6. Save to DB
    try {
      await pool.execute(
        'INSERT INTO $collection (id, tenant_id, data) VALUES (\$1, \$2, \$3) '
        'ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data',
        parameters: [id, tenantId, finalData],
      );

      // 7. Audit success
      if (securityProtocol != null && context != null) {
        await securityProtocol!.audit(
          context,
          SecurityAction.write(collection: collection, entityId: id),
          AuditResult.success(),
        );
      }
    } catch (e) {
      // 8. Audit failure
      if (securityProtocol != null && context != null) {
        await securityProtocol!.audit(
          context,
          SecurityAction.write(collection: collection, entityId: id),
          AuditResult.failure(e.toString()),
        );
      }
      rethrow;
    }
  }
}
```

---

## Примеры реализаций

### 1. JWT-based Security

```dart
class JWTSecurityService implements IVaultSecurityProtocol {
  final JWTValidator validator;
  final PermissionChecker permissionChecker;
  final AuditLogger auditLogger;
  final RateLimiter rateLimiter;

  // Реализация всех методов...
}
```

### 2. API Key Security

```dart
class APIKeySecurityService implements IVaultSecurityProtocol {
  final APIKeyStore keyStore;

  @override
  Future<SecurityContext> authenticate(SecurityRequest request) async {
    final apiKey = request.headers['X-API-Key'];
    if (apiKey == null) {
      throw SecurityException('Missing API key');
    }

    final keyInfo = await keyStore.validate(apiKey);
    if (keyInfo == null) {
      throw SecurityException('Invalid API key');
    }

    return SecurityContext(
      userId: keyInfo.userId,
      tenantId: keyInfo.tenantId,
      roles: keyInfo.roles,
      permissions: keyInfo.permissions,
    );
  }

  // Остальные методы...
}
```

### 3. Multi-Strategy Security

```dart
class MultiStrategySecurityService implements IVaultSecurityProtocol {
  final List<IVaultSecurityProtocol> strategies;

  @override
  Future<SecurityContext> authenticate(SecurityRequest request) async {
    // Попробовать каждую стратегию по очереди
    for (final strategy in strategies) {
      try {
        return await strategy.authenticate(request);
      } catch (e) {
        continue;
      }
    }

    throw SecurityException('Authentication failed');
  }

  // Остальные методы делегируют первой успешной стратегии...
}
```

---

## Deployment

### Development

```dart
// Без security — всё разрешено
final storage = PostgresVaultStorage(
  pool: pool,
  tenantId: tenantId,
  securityProtocol: NoOpSecurityProtocol(),
);
```

### Production

```dart
// С полной security
final securityService = JWTSecurityService(
  validator: JWTValidator(secret: Platform.environment['JWT_SECRET']!),
  permissionChecker: PostgresPermissionChecker(pool: pool),
  auditLogger: PostgresAuditLogger(pool: pool),
  rateLimiter: RedisRateLimiter(redis: redis),
);

final storage = PostgresVaultStorage(
  pool: pool,
  tenantId: tenantId,
  securityProtocol: securityService,
);
```

---

## Преимущества

1. ✅ **Инверсия зависимостей** — data layer не зависит от конкретной реализации
2. ✅ **Гибкость** — можно менять реализацию без изменения data layer
3. ✅ **Тестируемость** — легко мокировать для тестов
4. ✅ **Необязательность** — можно работать без security (dev mode)
5. ✅ **Универсальность** — не привязан к конкретной бизнес-логике
6. ✅ **Масштабируемость** — можно добавлять новые стратегии

---

## Заключение

**Security Protocol** — это мощный инструмент для контроля доступа, который:

- Живёт как интерфейс в `dart_vault`
- Реализуется в отдельном сервисе (`aq_security`)
- Необязателен (NoOp по умолчанию)
- Универсален (не знает о бизнес-логике)

Это правильная архитектура для универсального data layer!
