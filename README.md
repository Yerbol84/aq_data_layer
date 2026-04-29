# dart_vault — Универсальный Data Layer для AQ экосистемы

**Версия:** 0.4.0
**Статус:** Production Ready ✅
**Последнее обновление:** 2026-04-11

---

## 🎯 Философия

`dart_vault` — это универсальная система хранения данных, построенная по принципу **"тонкий клиент + чистая архитектура"**:

- ✅ **Клиент не знает о базе данных** — работает только с репозиториями
- ✅ **Единая схема** — все домены из `aq_schema`, используются везде одинаково
- ✅ **Унифицированные константы** — все компоненты используют `VersionedStorageContract`
- ✅ **Multi-tenancy** — изоляция данных на уровне PostgreSQL RLS
- ✅ **Три типа хранилищ** — Direct, Versioned, Logged для разных use cases

---

## 📊 Возможности

### Storage Types

| Тип | Назначение | Use Cases |
|-----|-----------|-----------|
| **Direct** | Простые CRUD операции | Проекты, настройки, справочники |
| **Versioned** | Версионирование с ветками и semver | Workflow graphs, документы с историей |
| **Logged** | Audit trail с полной историей | Workflow runs, audit logs |

### Инфраструктура

- ✅ PostgreSQL с JSONB и RLS
- ✅ Автоматическое создание схемы
- ✅ ACID транзакции
- ✅ HTTP RPC протокол
- ✅ Буферизация записей
- ✅ 97% покрытие тестами

---

## 🚀 Быстрый старт

### Клиент (Flutter приложение)

```dart
// ВАЖНО: Импортируйте ТОЛЬКО dart_vault.dart для клиента
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  // Подключиться к Data Service
  await Vault.connect('http://localhost:8765', tenantId: 'user-123');
  runApp(MyApp());
}

// Использовать репозитории
final workflows = Vault.instance.versioned<WorkflowGraph>(
  collection: WorkflowGraph.kCollection,
  fromMap: WorkflowGraph.fromMap,
);

// CRUD операции
final node = await workflows.createEntity(workflow);
await workflows.updateDraft(node.nodeId, updatedWorkflow);
final published = await workflows.publishDraft(node.nodeId);

// Работа с файлами (Artifact)
final artifactVault = ArtifactVault(tenantId: 'user-123');
final files = artifactVault.artifacts<MyFile>(
  collection: 'uploads',
  fromMap: MyFile.fromMap,
);

// Работа с документами и векторным поиском (Knowledge)
final knowledgeVault = KnowledgeVault(tenantId: 'user-123');
final docs = knowledgeVault.documents<MyDoc>(
  collection: 'documents',
  vectorSize: 1536,
  fromMap: MyDoc.fromMap,
  embed: (text) => openai.embed(text),
);
```

### Сервер (Data Service)

```dart
// ВАЖНО: Импортируйте server.dart для серверной части
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

void main() async {
  final pool = await Pool.connect(
    Endpoint(
      host: 'localhost',
      database: 'aq_studio',
      username: 'postgres',
      password: 'postgres',
    ),
    settings: PoolSettings(maxConnectionCount: 10),
  );

  // Создать registry с security компонентами
  final registry = VaultRegistry(
    storageFactory: (tenantId) => PostgresVaultStorage(
      pool: pool,
      tenantId: tenantId,
      rateLimiter: VaultRateLimiter(store: InMemoryRateLimitStore()),
      auditLogger: PostgresAuditLogger(pool: pool),
    ),
    deployer: PostgresSchemaDeployer(pool: pool),
  );

  // Регистрация доменов из aq_schema
  for (final domain in AqDomains.all) {
    registry.register(DomainRegistration(
      collection: domain.collection,
      mode: domain.kind.toStorageMode(),
      fromMap: domain.fromMap,
    ));
  }

  await registry.deploy(); // Создаёт таблицы автоматически

  final handler = createVaultHandler(registry);
  await io.serve(handler, 'localhost', 8765);
}
```

---

## 📚 Документация

### Основные документы

- **[doc/README.md](doc/README.md)** — навигация по всей документации
- **[doc/guides/QUICK_START.md](doc/guides/QUICK_START.md)** — быстрый старт для новичков
- **[doc/guides/USAGE_GUIDE.md](doc/guides/USAGE_GUIDE.md)** — полное руководство пользователя

### Архитектура

- **[doc/architecture/ARCHITECTURE.md](doc/architecture/ARCHITECTURE.md)** — полная архитектура системы
- **[doc/architecture/KEY_DECISIONS.md](doc/architecture/KEY_DECISIONS.md)** — ключевые архитектурные решения
- **[doc/architecture/LOGGED_STORABLE_CONVENTION.md](doc/architecture/LOGGED_STORABLE_CONVENTION.md)** — конвенции LoggedStorable

### Отчёты

- **[doc/reports/COMPLIANCE_REPORT.md](doc/reports/COMPLIANCE_REPORT.md)** — отчёт о соответствии production требованиям
- **[doc/reports/PRODUCTION_READY_STATUS.md](doc/reports/PRODUCTION_READY_STATUS.md)** — статус готовности к production

---

## 🧪 Тестирование

```bash
# Запустить PostgreSQL
docker-compose up -d

# Запустить все тесты
dart test
```

**Результаты:** 34 теста прошли успешно, 97% покрытие кода.

---

## 📦 Установка

```yaml
dependencies:
  dart_vault: ^0.4.0
  aq_schema: ^1.0.0
```

**Клиент (Flutter/Dart приложение):**
```dart
// ТОЛЬКО клиентский API — Vault, репозитории, исключения
import 'package:dart_vault/dart_vault.dart';
```

**Сервер (Data Service):**
```dart
// Клиентский API + Storage + Deploy + Security
import 'package:dart_vault/server.dart';
```

**ВАЖНО:** Никогда не импортируйте `server.dart` в клиентском приложении!

---

## 🤝 Вклад

Проект находится в активной разработке. Приветствуются баг-репорты, предложения и pull requests.

---

## 📄 Лицензия

MIT
