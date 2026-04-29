# Развёртывание dart_vault Data Service

## Локальное развёртывание через Docker

### Предварительные требования

- Docker и Docker Compose установлены
- Порты 5432 (PostgreSQL) и 8765 (Data Service) свободны

### Быстрый старт

```bash
cd /app/work/deploys/aq_studio_dl_stack

# Остановить существующие контейнеры (если есть)
docker compose down

# Пересобрать data_service с последними изменениями
docker compose build --no-cache data_service

# Запустить стек (PostgreSQL + Data Service)
docker compose up -d

# Проверить логи
docker compose logs -f data_service

# Проверить статус
docker compose ps
```

### Структура стека

```
aq_studio_dl_stack/
├── docker-compose.yml       # Конфигурация стека
├── .env                      # Переменные окружения
├── init-db.sh               # Инициализация PostgreSQL
└── aq_studio_data/          # Данные PostgreSQL (volume)
```

### Компоненты

**1. PostgreSQL (postgres:14-alpine)**
- База данных: `aq_studio`
- Пользователь admin: `aq` / `aq_secret`
- Пользователь приложения: `aq_app` / `aq_app_secret` (без RLS bypass)
- Порт: 5432

**2. Data Service (aq_studio_data_service)**
- Регистрирует все домены из `AqDomains.all`
- Автоматически создаёт таблицы через `PostgresSchemaDeployer`
- Поддерживает RLS (Row Level Security) для multi-tenancy
- Порт: 8765

### Переменные окружения (.env)

```bash
# PostgreSQL
POSTGRES_DB=aq_studio
POSTGRES_USER=aq
POSTGRES_PASSWORD=aq_secret
POSTGRES_PORT=5432

# Data Service
DATA_SERVICE_PORT=8765

# Timezone
TZ=UTC
```

### Проверка работоспособности

```bash
# Проверить PostgreSQL
docker compose exec postgres psql -U aq -d aq_studio -c "\dt"

# Проверить Data Service
curl http://localhost:8765/health

# Handshake с Data Service
curl -X POST http://localhost:8765/vault/handshake \
  -H "Content-Type: application/json" \
  -d '{"tenantId": "test-user"}'
```

### Остановка и очистка

```bash
# Остановить контейнеры
docker compose down

# Остановить и удалить данные
docker compose down -v

# Полная очистка (включая образы)
docker compose down -v --rmi all
```

## Разработка без Docker

### Запуск PostgreSQL локально

```bash
# Установить PostgreSQL 14+
brew install postgresql@14  # macOS
apt install postgresql-14   # Ubuntu

# Создать базу данных
createdb aq_studio

# Создать пользователя приложения
psql aq_studio -c "CREATE ROLE aq_app WITH LOGIN PASSWORD 'aq_app_secret';"
psql aq_studio -c "GRANT ALL PRIVILEGES ON DATABASE aq_studio TO aq_app;"
```

### Запуск Data Service локально

```bash
cd /app/work/server_apps/aq_studio_data_service

# Установить зависимости
dart pub get

# Установить переменные окружения
export PG_HOST=localhost
export PG_PORT=5432
export PG_DB=aq_studio
export PG_USER=aq_app
export PG_PASSWORD=aq_app_secret
export PORT=8765

# Запустить сервис
dart run bin/server.dart
```

## Интеграция с Flutter приложением

После запуска стека, подключите Flutter приложение:

```dart
import 'package:dart_vault/dart_vault.dart';

void main() async {
  // Подключиться к локальному Data Service
  await Vault.connect(
    'http://localhost:8765',
    tenantId: 'user-123',
  );

  runApp(MyApp());
}
```

## Troubleshooting

### Data Service не запускается

```bash
# Проверить логи
docker compose logs data_service

# Проверить подключение к PostgreSQL
docker compose exec data_service ping postgres
```

### PostgreSQL не принимает подключения

```bash
# Проверить статус
docker compose exec postgres pg_isready -U aq

# Проверить логи
docker compose logs postgres
```

### Порты заняты

```bash
# Изменить порты в .env
POSTGRES_PORT=5433
DATA_SERVICE_PORT=8766

# Пересоздать контейнеры
docker compose up -d --force-recreate
```

## Production deployment

Для production используйте:
- Managed PostgreSQL (AWS RDS, Google Cloud SQL, Supabase)
- Kubernetes для Data Service
- Secrets Manager для паролей
- Load Balancer для масштабирования

См. документацию в `doc/guides/PRODUCTION_DEPLOYMENT.md`
