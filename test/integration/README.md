# Integration Tests

Интеграционные тесты для проверки работы с реальной PostgreSQL базой данных.

## Требования

1. PostgreSQL 14+ установлен и запущен
2. Создана тестовая база данных `dart_vault_test`

## Создание тестовой базы

```bash
# macOS/Linux
createdb dart_vault_test

# Или через psql
psql postgres
CREATE DATABASE dart_vault_test;
\q
```

## Запуск тестов

```bash
cd pkgs/dart_vault_package

# Запуск всех интеграционных тестов
dart test test/integration/

# Запуск конкретного теста
dart test test/integration/postgres_integration_test.dart

# Запуск с подробным выводом
dart test test/integration/ --reporter=expanded
```

## Настройка подключения

Если ваши настройки PostgreSQL отличаются от стандартных, измените параметры в `postgres_integration_test.dart`:

```dart
connection = await Connection.open(
  Endpoint(
    host: 'localhost',        // ← ваш хост
    database: 'dart_vault_test',  // ← ваша тестовая БД
    username: 'postgres',     // ← ваш пользователь
    password: 'postgres',     // ← ваш пароль
  ),
  settings: ConnectionSettings(
    sslMode: SslMode.disable,
  ),
);
```

## Что тестируется

### CRUD операции
- ✅ Создание сущности (save)
- ✅ Получение по ID (findById)
- ✅ Обновление существующей сущности
- ✅ Удаление (delete)
- ✅ Проверка существования (exists)

### Запросы
- ✅ Получение всех сущностей (findAll)
- ✅ Фильтрация (equals, greaterThan, greaterOrEqual)
- ✅ Сортировка (ascending/descending)
- ✅ Пагинация (limit/offset)
- ✅ Подсчёт (count)
- ✅ Постраничный запрос (queryPage)

### Multi-tenancy
- ✅ Изоляция данных между тенантами
- ✅ Одинаковые ID в разных тенантах
- ✅ Удаление в одном тенанте не влияет на другой

### Batch операции
- ✅ Массовое сохранение (putAll)

## Очистка после тестов

Тесты автоматически очищают данные после выполнения. Если нужно вручную очистить базу:

```sql
DROP TABLE IF EXISTS test_entities;
DROP TABLE IF EXISTS _vault_migrations;
```

## Troubleshooting

### Ошибка подключения

```
SocketException: Connection refused
```

**Решение:** Убедитесь что PostgreSQL запущен:
```bash
# macOS
brew services start postgresql@14

# Linux
sudo systemctl start postgresql
```

### Ошибка аутентификации

```
PostgreSQLException: password authentication failed
```

**Решение:** Проверьте настройки в `pg_hba.conf` или измените параметры подключения в тесте.

### База данных не существует

```
PostgreSQLException: database "dart_vault_test" does not exist
```

**Решение:** Создайте базу данных:
```bash
createdb dart_vault_test
```
