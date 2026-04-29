# PostgreSQL Implementation Notes

## TODO: Views (SQL Views)

**Требование:** Поддержка SQL Views для комбинированных запросов.

**Проблема:**
- Сейчас таблицы создаются напрямую из JSON Schema
- Нужна возможность создавать Views - комбинированные SELECT запросы
- Views должны создаваться автоматически при старте сервера

**Возможные подходы:**

1. **Расширить JSON Schema:**
   ```dart
   {
     'type': 'view',
     'query': 'SELECT ... FROM ... JOIN ...',
     'dependencies': ['table1', 'table2']
   }
   ```

2. **Отдельный ViewRegistration:**
   ```dart
   registry.registerView(ViewRegistration(
     name: 'user_with_profile',
     query: '''
       SELECT u.*, p.*
       FROM users u
       LEFT JOIN profiles p ON u.id = p.user_id
     ''',
   ));
   ```

3. **Декларативный подход через домены:**
   - Домен может объявить что он является View
   - SchemaDeployer создаёт CREATE VIEW вместо CREATE TABLE

**Когда реализовывать:**
- После завершения базовой функциональности (Direct, Versioned, Logged)
- Когда появится реальная потребность в сложных JOIN запросах
- Возможно в Sprint 2 или 3

**Связанные задачи:**
- Валидация зависимостей (view не может быть создан до создания таблиц)
- Обновление views при изменении схемы таблиц
- Миграции для views

---

## Текущая архитектура инициализации БД

**Процесс запуска Data Service:**

1. **Создание VaultRegistry:**
   ```dart
   final registry = VaultRegistry(
     storageFactory: (tenantId) => PostgresVaultStorage(...),
     deployer: PostgresSchemaDeployer(pool: pool),
   );
   ```

2. **Регистрация доменов:**
   ```dart
   registry
     ..register(DomainRegistration(
         collection: 'workflows',
         mode: StorageMode.versioned,
         fromMap: WorkflowGraph.fromMap,
         jsonSchema: WorkflowGraph.kJsonSchema,
     ))
     ..register(...);
   ```

3. **Deploy схемы (автоматическое создание таблиц):**
   ```dart
   await registry.deploy(); // ← Здесь создаются ВСЕ таблицы
   ```

4. **Запуск HTTP сервера:**
   ```dart
   final handler = createVaultHandler(registry);
   await io.serve(handler, 'localhost', 8765);
   ```

**Что происходит в registry.deploy():**

1. `PostgresSchemaDeployer.ensureSchema(domains)` вызывается
2. Для каждого домена:
   - Проверяется существование таблицы
   - Если не существует → CREATE TABLE из JSON Schema
   - Создаются индексы
   - Создаются дополнительные таблицы (_versions, _current, _log)
3. Проверяются миграции
4. Применяются необходимые миграции

**Валидация:**
- TODO: Добавить проверку соответствия существующей схемы с JSON Schema
- TODO: Если схема не соответствует → выбросить ошибку или применить миграцию
- TODO: Логировать все изменения схемы

---

## Multi-tenancy Architecture

**Принцип:** Один набор таблиц для всех тенантов, фильтрация через `tenant_id`.

**Преимущества:**
- Масштабируемость (10000+ тенантов без проблем)
- Простота миграций (одна миграция для всех)
- Эффективное использование индексов

**Структура таблиц:**
```sql
CREATE TABLE workflows (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,  -- ← Изоляция тенантов
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)  -- ← Композитный ключ
);

CREATE INDEX idx_workflows_tenant ON workflows(tenant_id);
```

**Все запросы автоматически фильтруются:**
```sql
SELECT data FROM workflows
WHERE tenant_id = 'company-123' AND id = 'wf-001';
```

---

## Режимы хранения (Storage Modes)

### 1. Direct Mode
**Таблицы:**
- `{collection}` - основная таблица

**Использование:**
- Простые сущности без истории
- Настройки, метаданные
- Пример: AqStudioProject

### 2. Versioned Mode
**Таблицы:**
- `{collection}_versions` - все версии (node_id, entity_id, version, status, branch, data)
- `{collection}_current` - текущая версия (entity_id → node_id)

**Использование:**
- Сущности с версионированием
- Ветки, черновики, публикация
- Пример: WorkflowGraph, InstructionGraph

### 3. Logged Mode
**Таблицы:**
- `{collection}` - текущее состояние
- `{collection}_log` - аудит лог (entry_id, operation, actor_id, changes, timestamp)

**Использование:**
- Сущности с аудитом
- История изменений, откат
- Пример: WorkflowRun, Session

---

## JSON Schema Format

**Требования к JSON Schema в доменах:**

```dart
static const kJsonSchema = {
  'type': 'object',
  'properties': {
    'id': {'type': 'string', 'format': 'uuid'},
    'tenantId': {'type': 'string'},
    'ownerId': {'type': 'string'},
    'name': {'type': 'string'},
    'nodes': {'type': 'array', 'items': {'type': 'object'}},
  },
  'required': ['id', 'tenantId', 'ownerId', 'name'],
};
```

**Поддерживаемые типы:**
- `string` → TEXT
- `number` / `integer` → NUMERIC / INTEGER
- `boolean` → BOOLEAN
- `array` → JSONB (хранится как JSON)
- `object` → JSONB (хранится как JSON)

**Форматы:**
- `uuid` → TEXT (валидация на уровне приложения)
- `date-time` → TIMESTAMPTZ (конвертация при сохранении)
- `email` → TEXT (валидация на уровне приложения)

**Примечание:** Все сложные типы (array, object) хранятся в JSONB колонке `data`.
Индексы создаются через `data->>'field'` синтаксис.

---

## Миграции

**Когда нужны миграции:**
1. Переименование поля
2. Изменение типа поля
3. Изменение формата данных
4. Добавление/удаление индексов

**Пример миграции:**
```dart
const migration = DomainMigration(
  collection: 'workflows',
  fromVersion: '1.0.0',
  toVersion: '2.0.0',
  description: 'Rename dataJson → graphData',
  transform: (data) {
    if (!data.containsKey('dataJson')) return null;
    return {...data, 'graphData': data.remove('dataJson')};
  },
  indexesToCreate: [VaultIndex(name: 'idx_type', field: 'type')],
  indexesToDrop: ['idx_old_field'],
);
```

**Процесс применения:**
1. Проверка `_vault_migrations` таблицы
2. Если миграция не применена:
   - Загрузка всех записей
   - Применение transform к каждой записи
   - Обновление записей
   - Создание/удаление индексов
   - Запись в `_vault_migrations`

---

## Следующие шаги

1. ✅ Исправить ошибки компиляции PostgresVaultStorage
2. ✅ Добавить недостающие методы VaultStorage
3. ✅ Добавить поддержку всех VaultOperator (включая notInList)
4. ⚠️ Добавить валидацию схемы при старте
5. ⚠️ Написать интеграционные тесты
6. ⚠️ Создать пример с реальной PostgreSQL
7. ⚠️ Реализовать транзакции (сейчас просто проброс)
8. ⚠️ Реализовать watchChanges через LISTEN/NOTIFY
9. ❌ Views (отложено на будущее)
