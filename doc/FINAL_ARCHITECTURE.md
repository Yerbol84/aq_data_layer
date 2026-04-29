# dart_vault — Финальная архитектура

**Дата:** 2026-04-15  
**Версия:** 0.4.0  
**Статус:** Production Ready ✅

---

## 🎯 Философия

`dart_vault` — это **универсальный data layer**, который:

- ✅ **Не знает о бизнес-логике** — работает только со `Storable` и их типами
- ✅ **Не знает о доменах** — графы, проекты, воркеры — это уровень приложения
- ✅ **Предоставляет интерфейсы** — реализация security живёт отдельно
- ✅ **Необязательная безопасность** — если не инициализирована, всё разрешено

---

## 📐 Архитектура

```
┌─────────────────────────────────────────────────────────────────┐
│                    Application Layer                            │
│  (aq_studio, aq_graph_engine, your_app)                        │
│                                                                 │
│  Здесь живёт бизнес-логика:                                    │
│  - Роли (Worker, Admin, Resource)                              │
│  - Домены (WorkflowGraph, Project, etc.)                       │
│  - Бизнес-правила                                              │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ использует
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    dart_vault (Data Layer)                      │
│                                                                 │
│  Универсальный data layer:                                     │
│  - Работает со Storable (Direct, Versioned, Logged)           │
│  - Не знает о графах, проектах, воркерах                      │
│  - Предоставляет интерфейс IVaultSecurityProtocol             │
│                                                                 │
│  ┌──────────────┐         зависит от        ┌───────────┐     │
│  │ VaultStorage │◄────────────────────────────│ IVaultSecurity│     │
│  │              │                            │ Protocol  │     │
│  └──────────────┘                            └─────▲─────┘     │
│                                                    │            │
└────────────────────────────────────────────────────┼────────────┘
                                                     │
                                                     │ реализует
                         ┌───────────────────────────┴─────────────┐
                         │                                         │
              ┌──────────▼──────────┐           ┌─────────────────▼────────┐
              │ NoOpSecurityProtocol│           │ aq_security              │
              │ (всё разрешено)     │           │ (ваша реализация)        │
              └─────────────────────┘           │ - JWT validation         │
                                                │ - Role-based access      │
                                                │ - Rate limiting          │
                                                │ - Audit logging          │
                                                └──────────────────────────┘
```

---

## 📦 Структура пакета

### Клиентский API (`lib/dart_vault.dart`)

```dart
import 'package:dart_vault/dart_vault.dart';

// Доступно клиенту:
// - Vault (singleton)
// - DirectRepository, VersionedRepository, LoggedRepository
// - ArtifactVault, KnowledgeVault
// - VaultException

await Vault.connect('http://localhost:8765', tenantId: 'user-123');
final repo = Vault.instance.versioned<WorkflowGraph>(...);
```

**Что НЕ доступно:**
- ❌ Storage реализации (PostgresVaultStorage, etc.)
- ❌ Security компоненты (rate limiting, audit, etc.)
- ❌ Deploy компоненты (VaultRegistry, SchemaDeployer)

### Серверный API (`lib/server.dart`)

```dart
import 'package:dart_vault/server.dart';
import 'package:dart_vault/security_protocol.dart';

// Доступно серверу:
// - Всё из клиентского API
// - Storage реализации
// - Security компоненты
// - Deploy компоненты
// - IVaultSecurityProtocol (интерфейс)
```

### Security Protocol (`lib/security_protocol.dart`)

```dart
import 'package:dart_vault/security_protocol.dart';

// Интерфейс для системы безопасности:
// - IVaultSecurityProtocol (интерфейс)
// - NoOpSecurityProtocol (всё разрешено)
// - SecurityContext, SecurityAction, etc. (DTOs)
```

---

## 🔐 Security Protocol

### Концепция

**Security Protocol** — это **интерфейс-порт** для системы безопасности:

1. **Data layer зависит от интерфейса** — не от реализации
2. **Реализация живёт отдельно** — в `aq_security` или вашем сервисе
3. **Необязательный** — если `null`, используется `NoOpSecurityProtocol`
4. **Универсальный** — не знает о бизнес-логике

### Интерфейс

```dart
abstract interface class IVaultSecurityProtocol {
  // 1. Authentication — Кто ты?
  Future<SecurityContext> authenticate(SecurityRequest request);

  // 2. Authorization — Что ты можешь делать?
  Future<bool> authorize(SecurityContext context, SecurityAction action);

  // 3. Audit — Что произошло?
  Future<void> audit(SecurityContext context, SecurityAction action, AuditResult result);

  // 4. Rate Limiting — Не слишком ли часто?
  Future<RateLimitResult> checkRateLimit(SecurityContext context, RateLimitKey key);

  // 5. Validation — Корректны ли данные?
  Future<ValidationResult> validateInput(SecurityContext context, String collection, Map<String, dynamic> data);

  // 6. Encryption — Нужно ли шифровать?
  Future<Map<String, dynamic>> encryptSensitiveFields(SecurityContext context, String collection, Map<String, dynamic> data);
  Future<Map<String, dynamic>> decryptSensitiveFields(SecurityContext context, String collection, Map<String, dynamic> data);
}
```

### Использование

**Development (без security):**

```dart
final storage = PostgresVaultStorage(
  pool: pool,
  tenantId: tenantId,
  securityProtocol: NoOpSecurityProtocol(), // Всё разрешено
);
```

**Production (с security):**

```dart
// Ваша реализация в отдельном пакете
final securityService = JWTSecurityService(
  validator: JWTValidator(secret: Platform.environment['JWT_SECRET']!),
  permissionChecker: PostgresPermissionChecker(pool: pool),
  auditLogger: PostgresAuditLogger(pool: pool),
  rateLimiter: RedisRateLimiter(redis: redis),
);

final storage = PostgresVaultStorage(
  pool: pool,
  tenantId: tenantId,
  securityProtocol: securityService, // Ваша реализация
);
```

---

## 🚀 Использование

### 1. Клиент (Flutter приложение)

```dart
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  // Подключиться к Data Service
  await Vault.connect('http://localhost:8765', tenantId: 'user-123');
  runApp(MyApp());
}

// Использовать репозитории
class ProjectsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final projects = Vault.instance.direct<AqStudioProject>(
      collection: 'projects',
      fromMap: AqStudioProject.fromMap,
    );

    return FutureBuilder(
      future: projects.findAll(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return CircularProgressIndicator();
        return ProjectsList(projects: snapshot.data!);
      },
    );
  }
}
```

### 2. Сервер (Data Service)

```dart
import 'package:dart_vault/server.dart';
import 'package:dart_vault/security_protocol.dart';
import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

void main() async {
  final pool = await Pool.connect(...);

  // Опционально: создать security service
  final securityService = MySecurityService(); // Ваша реализация

  // Создать registry
  final registry = VaultRegistry(
    storageFactory: (tenantId) => PostgresVaultStorage(
      pool: pool,
      tenantId: tenantId,
      securityProtocol: securityService, // Опционально
    ),
    deployer: PostgresSchemaDeployer(pool: pool),
  );

  // Зарегистрировать домены из aq_schema
  for (final domain in AqDomains.all) {
    registry.register(DomainRegistration(
      collection: domain.collection,
      mode: domain.kind.toStorageMode(),
      fromMap: domain.fromMap,
    ));
  }

  await registry.deploy(); // Создать таблицы

  final handler = createVaultHandler(registry);
  await serve(handler, 'localhost', 8765);
}
```

### 3. Security Service (отдельный пакет)

```dart
// В пакете aq_security или вашем сервисе
import 'package:dart_vault/security_protocol.dart';

class JWTSecurityService implements IVaultSecurityProtocol {
  final JWTValidator validator;
  final PermissionChecker permissionChecker;

  @override
  Future<SecurityContext> authenticate(SecurityRequest request) async {
    // Извлечь JWT токен
    final authHeader = request.headers['Authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw SecurityException('Missing Authorization header');
    }

    final token = authHeader.substring(7);
    final payload = await validator.verify(token);

    return SecurityContext(
      userId: payload['sub'] as String,
      tenantId: payload['tenant_id'] as String,
      roles: (payload['roles'] as List).cast<String>(),
      permissions: (payload['permissions'] as List).cast<String>(),
    );
  }

  @override
  Future<bool> authorize(SecurityContext context, SecurityAction action) async {
    // Проверить права доступа
    if (context.isAdmin) return true;

    return await permissionChecker.hasPermission(
      userId: context.userId,
      operation: action.operation,
      collection: action.collection,
      entityId: action.entityId,
    );
  }

  // Остальные методы...
}
```

---

## 📊 Разделение ответственности

| Уровень | Ответственность | Примеры |
|---------|----------------|---------|
| **Application** | Бизнес-логика, роли, домены | Worker, Admin, WorkflowGraph, Project |
| **dart_vault** | CRUD, версионирование, интерфейс security | Vault, Repository, IVaultSecurityProtocol |
| **aq_security** | Реализация security | JWT validation, ACL, rate limiting, audit |
| **PostgreSQL** | Хранение данных, RLS | Таблицы, индексы, RLS политики |

---

## ✅ Преимущества архитектуры

1. ✅ **Универсальность** — data layer не привязан к конкретным доменам
2. ✅ **Инверсия зависимостей** — зависит от интерфейса, не от реализации
3. ✅ **Гибкость** — можно менять security без изменения data layer
4. ✅ **Тестируемость** — легко мокировать security для тестов
5. ✅ **Необязательность** — можно работать без security (dev mode)
6. ✅ **Масштабируемость** — легко добавлять новые стратегии security

---

## 📚 Документация

- **[SECURITY_PROTOCOL.md](doc/guides/SECURITY_PROTOCOL.md)** — полное руководство по Security Protocol
- **[DEPLOYMENT.md](DEPLOYMENT.md)** — развёртывание Docker стека
- **[ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md)** — детальная архитектура
- **[USAGE_GUIDE.md](doc/guides/USAGE_GUIDE.md)** — руководство пользователя

---

## 🎯 Следующие шаги

1. **Реализовать `aq_security`** — пакет с JWT validation, ACL, rate limiting
2. **Интегрировать с `aq_auth_service`** — сервис аутентификации
3. **Создать Flutter приложение** — UI для работы с данными
4. **Добавить тесты** — интеграционные тесты с security

---

## 🏆 Итог

`dart_vault` теперь является **правильным универсальным data layer**:

- Не знает о бизнес-логике
- Предоставляет интерфейс для security
- Реализация security живёт отдельно
- Необязательная безопасность

Это **правильная архитектура** для масштабируемой системы!
