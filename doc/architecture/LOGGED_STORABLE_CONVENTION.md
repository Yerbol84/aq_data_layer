# LoggedStorable Convention

## Суффикс для log таблиц

**ПРАВИЛО:** LoggedStorable добавляет суффикс `_log` (одинарное подчёркивание)

### Примеры

| Основная таблица | Log таблица |
|------------------|-------------|
| `security_sessions` | `security_sessions_log` |
| `security_api_keys` | `security_api_keys_log` |
| `rbac_access_logs` | `rbac_access_logs_log` |
| `rbac_alerts` | `rbac_alerts_log` |

### Реализация

**Файл:** `lib/storage/logged_repository_impl.dart:53`
```dart
_logCollection = '${collection}_log',
```

**Файл:** `lib/storage/postgres/postgres_schema_deployer.dart:418`
```sql
CREATE TABLE IF NOT EXISTS ${domain.collection}_log (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)
);
```

### ❌ НЕПРАВИЛЬНО

- `${collection}__log` (двойное подчёркивание) - **НЕ ИСПОЛЬЗУЕТСЯ**
- `${collection}-log` (дефис) - **НЕ ИСПОЛЬЗУЕТСЯ**

### ✅ ПРАВИЛЬНО

- `${collection}_log` (одинарное подчёркивание)

## Проверка

Все LoggedStorable коллекции должны иметь соответствующую `_log` таблицу:

```bash
# Проверить в PostgreSQL
SELECT tablename FROM pg_tables 
WHERE tablename LIKE '%_log' 
AND schemaname = 'public';
```

Ожидаемый результат:
- `security_sessions_log`
- `security_api_keys_log`
- `rbac_access_logs_log`
- `rbac_alerts_log`
